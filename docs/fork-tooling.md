# Fork tooling

The developer tools this fork adds under `Scripts/fork/`. None of them ships a byte in the app, runs
in the background or adds a setting: each one runs when you start it and leaves nothing behind.
[`FORK.md`](../FORK.md) has the short version.

## Invariants

- **`install.sh` never runs `tccutil`.** A reset silently withdraws grants the user gave; when the
  code requirement changes, the script stops and prints the reset lines for the user to run.
- **It never replaces a bundle that is not the fork's.** Upstream's stable app has the same file
  name, `/Applications/Tinycast.app`, and its own grants and settings.
- **There is always an app installed.** The new copy is staged and verified on the destination
  volume, the old one is quit, and the swap is two renames, the first undone if the second fails.
- **It never touches `project.yml` or adds an `.xcconfig`.** Bundle id, identity and version travel
  on the `xcodebuild` line, so the fork's install path never conflicts with upstream.

## `Scripts/fork/install.sh`

```sh
Scripts/fork/install.sh [--no-launch] [--force-quit] [--accept-new-identity]
Scripts/fork/install.sh --rollback      # the copy the last install replaced
Scripts/fork/install.sh --self-check    # resolve and list; build, quit, move and register nothing
```

| Environment | Default | Meaning |
| --- | --- | --- |
| `TINYCAST_SIGN_IDENTITY` | the single `Apple Development: …` identity | full name to sign with |
| `TINYCAST_FORK_BUNDLE_ID` | `com.tinycast.app.fork` | `TINYCAST_BUNDLE_IDENTIFIER` for the build |
| `TINYCAST_INSTALL_PATH` | `/Applications/Tinycast.app` | where the app is installed |
| `DEVELOPER_DIR` | `/Applications/Xcode.app/Contents/Developer` | as `build-dmg.sh` |

Exit codes: 0 installed · 1 build or verification failed · 2 refused (a foreign bundle, a changed
identity, an ambiguous certificate) · 3 the app did not quit · 4 the swap failed and was rolled back ·
64 usage. Working files live in `build/fork/` (`DerivedData/`, `build.log`, `install.log`,
`Tinycast.previous`), which `.gitignore` already covers.

The order of the steps is the design:

| Step | What happens |
| --- | --- |
| Identity | Exactly one valid `Apple Development` identity, by name and by SHA-1. Two certificates with one name make `codesign` fail as ambiguous, so the script lists them instead. |
| Version | `MARKETING_VERSION` is `git describe` without the `v` (`0.12.2-beta.125-11-g7575cbad`, `-dirty` on a dirty tree), `CURRENT_PROJECT_VERSION` the commit count. Tags come from upstream: a fresh clone needs `git fetch upstream --tags`. |
| Build | Release, this Mac's architecture only, signed with `--timestamp=none` so it needs no network. |
| Verify | The bundle id is the fork's, `Scripts/verify-signature.sh` passes, and the designated requirement equals the installed copy's (else exit 2 unless `--accept-new-identity`). |
| Stage | `ditto` to `/Applications/.Tinycast-staged-<pid>`. No `.app` suffix, so LaunchServices ignores it. |
| Detach | When an ancestor process runs from inside the installed bundle (an agent, `run_command`, a custom command), the rest runs in a new session and logs to `build/fork/install.log`: quitting Tinycast reaps its agents' process trees. |
| Quit | `osascript … to quit`, only while the app runs, so the quit goes through the app's own termination path (dictation stops, notes flush, the Hyper key remap is restored). It waits for the helpers too. `--force-quit` sends SIGTERM, then SIGKILL. |
| Swap | Installed → aside, staged → installed, the first rename undone on failure. The replaced copy becomes `build/fork/Tinycast.previous` for `--rollback`. |
| LaunchServices | `lsregister -f` on the installed app, then `-u` on every other registered copy of the fork's ids, including the Release products Xcode's `RegisterWithLaunchServices` step registered. `tinycast://`, `raycast://` and `open -b` then reach `/Applications`. |
| Relaunch | `open`, unless `--no-launch`, and a report: version, identity, requirement, path, size. |

macOS App Management can refuse the renames in `/Applications` with `Operation not permitted`. The
script names the setting (System Settings › Privacy & Security › App Management) and leaves the old
app in place.

### The Accessibility grant survives a reinstall

The unified log of 2026-10-22 showed `tccd` answering *allowed* for every reinstalled build: the
designated requirement pins the bundle id and the certificate's common name, both unchanged by a
rebuild or a certificate renewal. The `kAXErrorAPIDisabled` (-25211) answers that looked like a stale
grant came from long-lived target processes that never asked `tccd` (a Chrome window started before
the grant kept refusing after the grant was toggled; a freshly started Chrome worked). So when a
Screen Awareness capture is refused while other apps capture fine, quit and reopen the app you
captured before you touch the grant. The script's last line says the same.

### Manual sweep

1. `Scripts/fork/install.sh --self-check` prints the identity, the `git describe` version, the commit
   count, the paths, and any stale LaunchServices registration it would remove.
2. Install with the app running: it quits without a crash report, comes back, and About shows the new
   version.
3. `lsregister -dump | awk '/^path:/ { p = $0 } /^identifier: +com\.tinycast\.app\.fork$/ { print p }'`
   lists only `/Applications/Tinycast.app`.
4. Screen Awareness works on an app started after the install (Finder, TextEdit, a new Chrome), with
   no toggling of the grant.
5. Started from an agent's `run_command`, the script detaches, `build/fork/install.log` fills, and the
   app comes back.
6. `TINYCAST_INSTALL_PATH` pointing at a copy of upstream's `com.tinycast.app` is refused with exit 2.
7. `TINYCAST_SIGN_IDENTITY=-` (ad hoc) is refused with both requirements printed and exit 2.
8. `--rollback` restores the previous build; a second `--rollback` undoes it.
