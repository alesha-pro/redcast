# Shipping

The scripts that put Redcast on a Mac: `install.sh` builds this checkout into `/Applications`, and
`release.sh` publishes a signed, notarized release the installed app updates from. Neither ships a
byte in the app, runs in the background or adds a setting.

| Tool | Does |
| --- | --- |
| [`install.sh`](#scriptsinstallsh) | builds Redcast in Release, swaps it into `/Applications`, migrates an old `Tinycast.app` copy of Redcast |
| [`release.sh`](#scriptsreleasesh) | builds, signs with Developer ID, notarizes and publishes a Redcast release |

## Invariants

- **`install.sh` never runs `tccutil`.** A reset silently withdraws grants the user gave; when the
  code requirement changes, the script stops and prints the reset lines for the user to run.
- **It never replaces a bundle that is not the fork's.** Upstream's stable app is
  `/Applications/Tinycast.app`, the fork's own name before Redcast, with its own grants and settings.
  A `Tinycast.app` beside the destination is migrated only when it has the fork's bundle id and the
  new build's code requirement; any other stays, and the script says both are installed.
- **One copy of the fork is installed.** A fork `Tinycast.app` beside an installed `Redcast.app` is
  refused (exit 2) before anything builds: both would run on the same settings and data, and only one
  would be quit. An `install.sh` from before the rename, still in another worktree, is what puts it
  back, so merge `main` into a worktree before you install from it.
- **There is always an app installed.** The new copy is staged and verified on the destination
  volume, the old one is quit, and the swap is two renames, the first undone if the second fails.
- **It never touches `project.yml` or adds an `.xcconfig`.** Bundle id, identity and version travel
  on the `xcodebuild` line.
- **The two names travel together.** A Release build finds its Dictation helper as
  "*executable* Dictation" (`DictationWorker`), so a build that overrides `PRODUCT_NAME` must override
  `DICTATION_EXECUTABLE_NAME` to match. `verify-signature.sh` looks for the helper under the same
  name, so such a build fails verification instead of shipping with dictation broken.
- **The rename never breaks a lookup.** Redcast writes `.redcast` and `redcast://`, and still opens
  `.tinycast` and answers `tinycast://`; the fork's old bundle id moves over with a migration.
- **Started from Redcast, it leaves Redcast's process group before it builds.** An agent's
  `run_command` watchdog (120 s by default, 600 s at most) and Redcast's own quit both signal the
  whole group that started the script, and a Release build outlasts the watchdog. Only the refusals
  that need no build, an ambiguous identity and a foreign installed bundle, answer the caller first.

## `Scripts/install.sh`

```sh
Scripts/install.sh [--no-launch] [--force-quit] [--accept-new-identity]
Scripts/install.sh --rollback      # the copy the last install replaced
Scripts/install.sh --self-check    # resolve and list; build, quit, move and register nothing
Scripts/install.sh --self-test     # stubbed installs into $TMPDIR, one started from a fake app
```

Every build uses `Redcast/redcast.icon` (an Icon Composer file: a solid `#F23D32` fill under the white
mark). The menu-bar item draws `RedcastMenuBarIcon`, the same mark as a template.

| Environment | Default | Meaning |
| --- | --- | --- |
| `REDCAST_SIGN_IDENTITY` | the installed copy's identity, else the one `Developer ID Application`, else the one `Apple Development` | full name to sign with |
| `REDCAST_INSTALL_BUNDLE_ID` | `io.redcast.app` | `REDCAST_BUNDLE_IDENTIFIER` for the build |
| `REDCAST_LEGACY_BUNDLE_ID` | `com.tinycast.app.fork` | the fork's earlier id: an install under it is this fork, replaced, and migrated on first launch |
| `REDCAST_INSTALL_PATH` | `/Applications/Redcast.app` | where the app is installed; a fork `Tinycast.app` in the same folder is migrated |
| `DEVELOPER_DIR` | `/Applications/Xcode.app/Contents/Developer` | the Xcode to build with |

`REDCAST_LSREGISTER` replaces the `lsregister` binary. `--self-test` uses it for a rehearsal that
needs no certificate and touches neither `/Applications` nor LaunchServices. It copies the script into
a throwaway repository and puts stand-in `xcodebuild`, `osascript` and `open` first on `PATH`. The
fake build is named `Redcast.app` unless a `PRODUCT_NAME` is passed, is
signed ad hoc and passes `verify-signature.sh`, and its executables are one tiny launcher compiled with
`clang`. Starting the script through the installed fake app's launcher makes it count as started from
the app. The self-test proves eight things. An ad hoc build is refused with both requirements. The
script then detaches at once, and no build runs in the caller's process group. The new build is
swapped in as `Redcast.app` with a `Redcast Dictation` helper, and `--rollback` puts the old one back.
A fork `Tinycast.app` is checked against the new build's requirement, then migrated from a start inside
it: `Redcast.app` installed, the old copy in the rollback slot and unregistered, the grants and Launch
at login named in the summary. `--rollback` restores `Tinycast.app`, and a second one migrates again.
Upstream's `Tinycast.app` beside the destination is left alone and named, and that fresh install
keeps the rollback slot. A fork `Tinycast.app` beside a fork `Redcast.app` is named by
`--self-check` and refused by an install and by `--rollback`, before anything builds. A foreign
bundle at the destination is refused before anything detaches.

Exit codes: 0 installed · 1 build or verification failed · 2 refused (a foreign bundle, a second fork
copy, a changed identity, an ambiguous certificate, a rollback whose place is taken) · 3 the app did
not quit · 4 the swap failed and was rolled back · 64 usage. Working files live in `build/install/`
(`DerivedData.noindex/`, `build.log`, `install.log`, `Redcast.previous` and `Redcast.previous.origin`, the
path that copy was installed at), which `.gitignore` already covers. The slot changes only when a swap
replaced a copy: a fresh install keeps it, and a replaced copy that cannot be moved there stays beside
the app as `.Redcast-previous-<pid>`, named in the output, rather than being deleted.

The order of the steps is the design:

| Step | What happens |
| --- | --- |
| Identity | The installed copy's signer (its first `Authority`) when exactly one valid certificate carries that name; else the one valid `Developer ID Application`, else the one `Apple Development`, by name and by SHA-1. Signing with the installed copy's identity is what keeps every grant. Two certificates with one name make `codesign` fail as ambiguous, so the script lists them instead. A foreign installed bundle is refused here too, and so is a second fork copy under the old name; upstream's `Tinycast.app` beside it is named. |
| Detach | When an ancestor process runs from inside the installed bundle (an agent, `run_command`, a custom command), everything below runs in a new session and logs to `build/install/install.log`. The caller gets exit 0 at once and reads the outcome in the log. Before a migration the installed bundle is the old `Tinycast.app`. |
| Version | `MARKETING_VERSION` is `git describe` without the `v` (`0.12.2-beta.125-11-g7575cbad`, `-dirty` on a dirty tree), `CURRENT_PROJECT_VERSION` the commit count. Tags come from upstream: a fresh clone needs `git fetch upstream --tags`. |
| Build | Release as `Redcast.app` with its `Redcast Dictation` helper, this Mac's architecture only, signed with `--timestamp=none` so it needs no network. |
| Verify | The bundle id is the fork's, `Scripts/verify-signature.sh` passes (it finds the helper as "*app name* Dictation", as the app does), and the designated requirement equals the installed copy's, the old `Tinycast.app` before a migration (else exit 2 unless `--accept-new-identity`). An ad hoc signature's requirement is its cdhash, which every build changes. |
| Stage | `ditto` to `/Applications/.Redcast-staged-<pid>`. No `.app` suffix, so LaunchServices ignores it. |
| Quit | `osascript … to quit`, only while the app runs, so the quit goes through the app's own termination path (dictation stops, notes flush, the Hyper key remap is restored). It waits for the helpers too. `--force-quit` sends SIGTERM, then SIGKILL. |
| Swap | Installed → aside, staged → `Redcast.app`, the first rename undone on failure. The replaced copy, `Tinycast.app` in a migration, becomes `build/install/Redcast.previous` for `--rollback`, and its path `Redcast.previous.origin`. |
| LaunchServices | `lsregister -f` on the installed app, `-u` on the copy a migration moved away, then `-u` on every other registered copy of the fork's ids, including the Release products Xcode's `RegisterWithLaunchServices` step registered. `redcast://`, `raycast://` and `open -b` then reach `/Applications`. |
| Relaunch | `open`, unless `--no-launch`, and a report: version, identity, requirement, path, size, and after a migration the grants and Launch at login. |

macOS App Management can refuse the renames in `/Applications` with `Operation not permitted`. The
script names the setting (System Settings › Privacy & Security › App Management) and leaves the old
app in place.

### From Redcast.app to Redcast.app

Until the rename the fork installed itself as `/Applications/Tinycast.app`. The first install after
it finds that copy, and when its bundle id is the fork's it is the installed copy for every step:
its requirement is the one the build must match, it is what quits (gracefully, as always), and a run
started inside it detaches. The swap moves it aside and puts `Redcast.app` in place; the old copy
goes to the rollback slot and is unregistered, so Spotlight, `open -b` and the URL schemes find only
`Redcast.app`. `--self-check` prints this plan before anything happens.

- **Grants carry over.** TCC keys each grant by bundle id and designated requirement, and the
  requirement pins the bundle id and the certificate's name, neither of which the rename touches.
- **Launch at login may not.** `SMAppService` registered the old bundle; if Redcast does not open at
  login, switch Settings › General › Launch at login off and on. The install summary says so.
- **Rolling back.** The slot remembers where its copy was installed, so `--rollback` puts
  `Tinycast.app` back, moves `Redcast.app` into the slot and unregisters it; a second `--rollback`
  migrates again. A slot from before the rename has no origin and rolls back in place. A rollback
  whose place is taken by something else stops with exit 2.
- **Upstream's Tinycast.app** (`com.tinycast.app`, or Beta or Dev) is never moved or unregistered;
  the script installs `Redcast.app` beside it and says both are installed.
- **A second fork copy.** Every worktree that has not merged this change still installs
  `/Applications/Tinycast.app`: run from one after the migration, it installs and opens a second copy
  beside `Redcast.app` and unregisters `Redcast.app`. This script then refuses to install or roll back
  until that copy is quit and in the Trash; the next install registers `Redcast.app` again. Merge
  `main` into a worktree before installing from it.

### The Accessibility grant survives a reinstall

The unified log of 2026-10-22 showed `tccd` answering *allowed* for every reinstalled build: the
designated requirement pins the bundle id and the certificate's common name, both unchanged by a
rebuild or a certificate renewal. The `kAXErrorAPIDisabled` (-25211) answers that looked like a stale
grant came from long-lived target processes that never asked `tccd` (a Chrome window started before
the grant kept refusing after the grant was toggled; a freshly started Chrome worked). So when a
Screen Awareness capture is refused while other apps capture fine, quit and reopen the app you
captured before you touch the grant. The script's last line says the same.

### Manual sweep

1. `Scripts/install.sh --self-test` passes, and `--self-check` prints the identity, the
   `git describe` version, the commit count, the paths, and any stale LaunchServices registration it
   would remove.
2. Install with the app running: it quits without a crash report, comes back, and About shows the new
   version.
3. `lsregister -dump | awk '/^path:/ { p = $0 } /^identifier: +com\.redcast\.app\.fork$/ { print p }'`
   lists only `/Applications/Redcast.app`.
4. Screen Awareness works on an app started after the install (Finder, TextEdit, a new Chrome), with
   no toggling of the grant.
5. Started from an agent's `run_command` with the default timeout, the command returns within seconds,
   `build/install/install.log` shows the whole Release build, and the app comes back.
6. `REDCAST_INSTALL_PATH` pointing at a copy of upstream's `com.tinycast.app` is refused with exit 2.
7. `REDCAST_SIGN_IDENTITY=-` (ad hoc) is refused with both requirements printed and exit 2.
8. `--rollback` restores the previous build; a second `--rollback` undoes it.
9. The first install over a fork `Tinycast.app`: `--self-check` prints the migration, the install
   leaves only `Redcast.app` (Finder, Spotlight, the menu bar item and About say Redcast), Screen
   Awareness and dictation work with no new prompt, and the login item opens Redcast after a toggle.
   `--rollback` brings `Tinycast.app` back, and a second `--rollback` redoes the migration.

## `Scripts/release.sh`

```sh
Scripts/release.sh <version> [--universal] [--publish] [--notes FILE]
Scripts/release.sh <version> --dry-run | --self-check
```

Ships `MAJOR.MINOR.PATCH` from a clean `HEAD` already on `origin/main`: a Release build for Apple
silicon (`--universal` adds the `-Universal-` one an Intel Mac's updater needs), signed with the
keychain's one `Developer ID Application` identity and a secure timestamp, checked by
`verify-signature.sh`, notarized and stapled, then a zip (what the updater expands) and a signed,
notarized, stapled DMG. It tags `HEAD` `v<version>` as `Redcast <version>`, pushes the tag and
creates a **draft** release on the repository `ReleaseFeed.repository` names, with notes listing the
first-parent commits since the previous `Redcast …` tag; `--publish` skips the draft. Everything lands
in `build/release/<version>/`, a rejected notarization's log included.

- **The source decides where and whom to trust.** The repository comes from `ReleaseFeed.swift` and
  the team from `BundleSignature.developerID`; the script refuses an identity of another team, since
  no installed copy could update to it. Changing teams means committing the new team there first.
- **Secrets stay in the keychain.** Notarization reads the `redcast-notary` profile
  (`REDCAST_NOTARY_PROFILE`), which you store once with
  `xcrun notarytool store-credentials redcast-notary` and an App Store Connect API key or an
  app-specific password. The script never takes a secret as an argument.
- **`install.sh` signs like a release where it can.** With the Developer ID identity in the keychain
  a local install shares the release's requirement, so grants carry over both ways and the installed
  copy takes the next release; a copy signed with Apple Development is replaced by hand once. A copy
  at a dirty or untagged version never checks for updates at all.
- `--self-check` prints the version, identity, team, repository and output and builds nothing;
  `--dry-run` builds and packages with any identity (`REDCAST_RELEASE_IDENTITY`), turning the
  identity and team checks into warnings, and notarizes, tags and publishes nothing.
