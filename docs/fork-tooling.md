# Fork tooling

The developer tools this fork adds under `Scripts/fork/`. None of them ships a byte in the app, runs
in the background or adds a setting: each one runs when you start it and leaves nothing behind.
[`FORK.md`](../FORK.md) has the short version.

| Tool | Does |
| --- | --- |
| [`install.sh`](#scriptsforkinstallsh) | builds Redcast in Release, swaps it into `/Applications`, migrates a fork `Tinycast.app` |
| [`rebrand.mjs`](#scriptsforkrebrandmjs) | renames the app in both string catalogs, Tinycast to Redcast |
| [`sync-upstream.sh`](#scriptsforksync-upstreamsh) | merges upstream into a branch of its own and runs the gates |
| [`merge-xcstrings.mjs`](#scriptsforkmerge-xcstringsmjs) | the key-by-key catalog merge the sync uses |
| `xcstrings.mjs` | the catalog parser and Xcode-layout writer the two `.mjs` tools share |

## Invariants

- **`install.sh` never runs `tccutil`.** A reset silently withdraws grants the user gave; when the
  code requirement changes, the script stops and prints the reset lines for the user to run.
- **It never replaces a bundle that is not the fork's.** Upstream's stable app is
  `/Applications/Tinycast.app`, the fork's own name before Redcast, with its own grants and settings.
  A `Tinycast.app` beside the destination is migrated only when it has the fork's bundle id and the
  new build's code requirement; any other stays, and the script says both are installed.
- **There is always an app installed.** The new copy is staged and verified on the destination
  volume, the old one is quit, and the swap is two renames, the first undone if the second fails.
- **It never touches `project.yml` or adds an `.xcconfig`.** Bundle id, identity, version and the
  name (`PRODUCT_NAME=Redcast`, `DICTATION_EXECUTABLE_NAME="Redcast Dictation"`) travel on the
  `xcodebuild` line, as upstream's `release.yml` passes its own `PRODUCT_NAME`, so the fork's install
  path never conflicts with upstream.
- **The rename is visible only.** Nothing the code, macOS or the user's data looks up by name
  changes: the bundle id, `.tinycast`, `tinycast://`, Keychain services, paths and log subsystems stay.
  `rebrand.mjs` renames whole, capitalised words in catalog values and never a key.
- **Started from Tinycast, it leaves Tinycast's process group before it builds.** An agent's
  `run_command` watchdog (120 s by default, 600 s at most) and Tinycast's own quit both signal the
  whole group that started the script, and a Release build outlasts the watchdog. Only the refusals
  that need no build, an ambiguous identity and a foreign installed bundle, answer the caller first.
- **`sync-upstream.sh` never pushes and never guesses.** It merges into a branch of its own, resolves
  only the four files whose resolution is mechanical, and stops on anything else. When upstream
  rewrote history it re-anchors only on commits it can prove are already merged.
- **A sync branch lands by fast-forward or a merge commit, never squash or rebase.** Either drops
  upstream's ancestry, and the next sync would replay everything.

## `Scripts/fork/install.sh`

```sh
Scripts/fork/install.sh [--no-launch] [--force-quit] [--accept-new-identity]
Scripts/fork/install.sh --rollback      # the copy the last install replaced
Scripts/fork/install.sh --self-check    # resolve and list; build, quit, move and register nothing
Scripts/fork/install.sh --self-test     # stubbed installs into $TMPDIR, one started from a fake app
```

| Environment | Default | Meaning |
| --- | --- | --- |
| `TINYCAST_SIGN_IDENTITY` | the single `Apple Development: …` identity | full name to sign with |
| `TINYCAST_FORK_BUNDLE_ID` | `com.tinycast.app.fork` | `TINYCAST_BUNDLE_IDENTIFIER` for the build |
| `TINYCAST_INSTALL_PATH` | `/Applications/Redcast.app` | where the app is installed; a fork `Tinycast.app` in the same folder is migrated |
| `DEVELOPER_DIR` | `/Applications/Xcode.app/Contents/Developer` | as `build-dmg.sh` |

`TINYCAST_LSREGISTER` replaces the `lsregister` binary. `--self-test` uses it for a rehearsal that
needs no certificate and touches neither `/Applications` nor LaunchServices. It copies the script into
a throwaway repository and puts stand-in `xcodebuild`, `osascript` and `open` first on `PATH`. The
fake build is named by the `PRODUCT_NAME` and `DICTATION_EXECUTABLE_NAME` the script passes, is
signed ad hoc and passes `verify-signature.sh`, and its executables are one tiny launcher compiled with
`clang`. Starting the script through the installed fake app's launcher makes it count as started from
the app. The self-test proves seven things. An ad hoc build is refused with both requirements. The
script then detaches at once, and no build runs in the caller's process group. The new build is
swapped in as `Redcast.app` with a `Redcast Dictation` helper, and `--rollback` puts the old one back.
A fork `Tinycast.app` is checked against the new build's requirement, then migrated from a start inside
it: `Redcast.app` installed, the old copy in the rollback slot and unregistered, the grants and Launch
at login named in the summary. `--rollback` restores `Tinycast.app`, and a second one migrates again.
Upstream's `Tinycast.app` beside the destination is left alone and named. A foreign bundle at the
destination is refused before anything detaches.

Exit codes: 0 installed · 1 build or verification failed · 2 refused (a foreign bundle, a changed
identity, an ambiguous certificate, a rollback whose place is taken) · 3 the app did not quit · 4 the
swap failed and was rolled back · 64 usage. Working files live in `build/fork/` (`DerivedData/`,
`build.log`, `install.log`, `Tinycast.previous` and `Tinycast.previous.origin`, the path that copy was
installed at), which `.gitignore` already covers.

The order of the steps is the design:

| Step | What happens |
| --- | --- |
| Identity | Exactly one valid `Apple Development` identity, by name and by SHA-1. Two certificates with one name make `codesign` fail as ambiguous, so the script lists them instead. A foreign installed bundle is refused here too, and upstream's `Tinycast.app` beside it named. |
| Detach | When an ancestor process runs from inside the installed bundle (an agent, `run_command`, a custom command), everything below runs in a new session and logs to `build/fork/install.log`. The caller gets exit 0 at once and reads the outcome in the log. Before a migration the installed bundle is the old `Tinycast.app`. |
| Version | `MARKETING_VERSION` is `git describe` without the `v` (`0.12.2-beta.125-11-g7575cbad`, `-dirty` on a dirty tree), `CURRENT_PROJECT_VERSION` the commit count. Tags come from upstream: a fresh clone needs `git fetch upstream --tags`. |
| Build | Release as `Redcast.app` (`PRODUCT_NAME=Redcast`, `DICTATION_EXECUTABLE_NAME="Redcast Dictation"`), this Mac's architecture only, signed with `--timestamp=none` so it needs no network. |
| Verify | The bundle id is the fork's, `Scripts/verify-signature.sh` passes (`TINYCAST_DICTATION_NAME` tells it the helper's name), and the designated requirement equals the installed copy's, the old `Tinycast.app` before a migration (else exit 2 unless `--accept-new-identity`). An ad hoc signature's requirement is its cdhash, which every build changes. |
| Stage | `ditto` to `/Applications/.Redcast-staged-<pid>`. No `.app` suffix, so LaunchServices ignores it. |
| Quit | `osascript … to quit`, only while the app runs, so the quit goes through the app's own termination path (dictation stops, notes flush, the Hyper key remap is restored). It waits for the helpers too. `--force-quit` sends SIGTERM, then SIGKILL. |
| Swap | Installed → aside, staged → `Redcast.app`, the first rename undone on failure. The replaced copy, `Tinycast.app` in a migration, becomes `build/fork/Tinycast.previous` for `--rollback`, and its path `Tinycast.previous.origin`. |
| LaunchServices | `lsregister -f` on the installed app, `-u` on the copy a migration moved away, then `-u` on every other registered copy of the fork's ids, including the Release products Xcode's `RegisterWithLaunchServices` step registered. `tinycast://`, `raycast://` and `open -b` then reach `/Applications`. |
| Relaunch | `open`, unless `--no-launch`, and a report: version, identity, requirement, path, size, and after a migration the grants and Launch at login. |

macOS App Management can refuse the renames in `/Applications` with `Operation not permitted`. The
script names the setting (System Settings › Privacy & Security › App Management) and leaves the old
app in place.

### From Tinycast.app to Redcast.app

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
  the script installs `Redcast.app` beside it and says both are installed. A second fork copy under
  the old name next to an existing `Redcast.app` is only named, for you to remove.

### The Accessibility grant survives a reinstall

The unified log of 2026-10-22 showed `tccd` answering *allowed* for every reinstalled build: the
designated requirement pins the bundle id and the certificate's common name, both unchanged by a
rebuild or a certificate renewal. The `kAXErrorAPIDisabled` (-25211) answers that looked like a stale
grant came from long-lived target processes that never asked `tccd` (a Chrome window started before
the grant kept refusing after the grant was toggled; a freshly started Chrome worked). So when a
Screen Awareness capture is refused while other apps capture fine, quit and reopen the app you
captured before you touch the grant. The script's last line says the same.

### Manual sweep

1. `Scripts/fork/install.sh --self-test` passes, and `--self-check` prints the identity, the
   `git describe` version, the commit count, the paths, and any stale LaunchServices registration it
   would remove.
2. Install with the app running: it quits without a crash report, comes back, and About shows the new
   version.
3. `lsregister -dump | awk '/^path:/ { p = $0 } /^identifier: +com\.tinycast\.app\.fork$/ { print p }'`
   lists only `/Applications/Redcast.app`.
4. Screen Awareness works on an app started after the install (Finder, TextEdit, a new Chrome), with
   no toggling of the grant.
5. Started from an agent's `run_command` with the default timeout, the command returns within seconds,
   `build/fork/install.log` shows the whole Release build, and the app comes back.
6. `TINYCAST_INSTALL_PATH` pointing at a copy of upstream's `com.tinycast.app` is refused with exit 2.
7. `TINYCAST_SIGN_IDENTITY=-` (ad hoc) is refused with both requirements printed and exit 2.
8. `--rollback` restores the previous build; a second `--rollback` undoes it.
9. The first install over a fork `Tinycast.app`: `--self-check` prints the migration, the install
   leaves only `Redcast.app` (Finder, Spotlight, the menu bar item and About say Redcast), Screen
   Awareness and dictation work with no new prompt, and the login item opens Redcast after a toggle.
   `--rollback` brings `Tinycast.app` back, and a second `--rollback` Redcast.

## `Scripts/fork/rebrand.mjs`

```sh
node Scripts/fork/rebrand.mjs                 # rename in both catalogs, in place
node Scripts/fork/rebrand.mjs --check         # exit 1 while a key still needs it; changes nothing
node Scripts/fork/rebrand.mjs --self-test     # fixtures, and the committed catalogs round-trip
node Scripts/fork/rebrand.mjs --help          # usage and the exclusions with their reasons
```

The app's name comes from two places. The bundle's name is the build's: `install.sh` passes
`PRODUCT_NAME=Redcast`, `Info.plist` reads `CFBundleName` from it, and `Bundle.main.appDisplayName`
gives every surface built from it (the menu bar item and its accessibility name, About's title, the
app menu's Quit, Support, Updates) the new name. Text written with the name in it lives in
`Localizable.xcstrings` and `InfoPlist.xcstrings` (the privacy prompts and the backup type's
description), and that is what this script renames. Source keys never change, so upstream's
`String(localized:)` calls, the catalog's structure and every translation key stay upstream's.

For each entry whose key or values say `Tinycast` as a whole, capitalised word:

- **English** gets a `translated` value: the key with `Tinycast` renamed, or, when English already has
  text of its own (a plural, positional arguments, a usage string keyed by its `Info.plist` key), that
  text renamed in place.
- **Every other language** has the word renamed in each value, plural and device variations and
  substitutions included. Placeholders, punctuation, states and comments are untouched, as is every
  entry that does not say the name; the catalog is written back in Xcode's own layout, so only the
  renamed lines and the added English blocks change.
- **Kept:** lowercase `tinycast` (`.tinycast`, `tinycast://`, ids), the word inside another
  (`TinycastAgents`) or next to a `/` or `.` (paths, ids), a mention in a comment, and these keys,
  which speak about upstream rather than this app:

  | Key | Why it keeps Tinycast |
  | --- | --- |
  | `Based on Tinycast by Abue Ammar` | About's AGPL credit for the upstream app and its author |
  | `Join the Tinycast community` | About's Discord row links upstream's community |

A run is idempotent: the second one finds nothing to rename. `xcstringstool sync` with a Release
build's `.stringsdata` leaves the rebranded catalog byte for byte, English values included, so
`./Scripts/sync-strings.sh` keeps them too. `check-localizations.js` checks the English values'
specifiers like any translation's.

New text is written as upstream writes it, with Tinycast in the key and in its translations; run the
script before committing, and `--check` (a sync gate) fails until you do. A new key about upstream
itself joins `EXCLUDED` in the script with its reason. `sync-upstream.sh` runs it after every merge,
and `merge-xcstrings.mjs` compares the three sides rebranded, so upstream's edits to a string the
fork only renamed merge without a conflict to review.

Left as Tinycast on purpose, outside the catalogs: protocol and request identifiers (`User-Agent`,
MCP's OAuth `client_name`, ACP and Codex `clientInfo`), prompts sent to models, default export file
names (`Tinycast.tinycast`, `Tinycast-Quicklinks`), `NSHumanReadableCopyright`, the extension symbol
browser's bundled category and the extension bridge's "not supported in Tinycast extensions" error
(a harness asserts it), and the Debug channel's `Tinycast Dev.app`.

## `Scripts/fork/sync-upstream.sh`

```sh
Scripts/fork/sync-upstream.sh [--branch NAME] [--skip-gates] [--summary FILE] [--ci]
Scripts/fork/sync-upstream.sh --continue     # after resolving the conflicts it left and git add
Scripts/fork/sync-upstream.sh --self-test    # throwaway repos in $TMPDIR, no network, no Xcode
```

Exit codes: 0 merged and every gate passed · 1 merged, a gate failed · 2 conflicts left (locally the
merge stays in progress for `--continue`; `--ci` aborts it) · 3 upstream rewrote history in a way that
needs a human · 4 a precondition failed · 10 already up to date. It needs a clean tree on `main` (or
`--branch`), and `git`, `node`, `xcodegen`, `swiftlint` and `xcodebuild`; it adds the `upstream`
remote when it is missing.

1. **The last synced upstream commit** is the newest `Upstream-Sync:` trailer reachable from `HEAD`,
   else `upstream/main` when it is already merged, else the merge base. The trailer is what makes it
   work in CI, where no remote-tracking ref survives.
2. **Fetch** `upstream/main`, and upstream's tags, which feed `git describe`.
3. **A rewrite** (the last synced commit is no longer upstream's ancestor; upstream force-pushed five
   times between August and September 2026) is read with `git rev-list --cherry-mark`. A run of
   commits patch-equivalent to merged ones followed only by new ones is recorded with
   `git merge -s ours` up to the last equivalent, so the real merge gets a correct base. Interleaved
   new and equivalent commits, or a merged commit upstream dropped, exit 3 with both lists and a
   `git range-diff` in the summary.
4. **Merge** `--no-ff --no-commit` into `sync/upstream-<sha>` (`--ci`: the rolling `sync/upstream`).
5. **Resolve** what is mechanical:

   | Path | Resolution |
   | --- | --- |
   | `Tinycast.xcodeproj/project.pbxproj` | upstream's, then `xcodegen generate` |
   | `Tinycast/Resources/RaycastRuntime.generated.js` | upstream's, then rebuilt from the merged sources when the fork patches them |
   | `Tinycast/Resources/Localizable.xcstrings`, `InfoPlist.xcstrings` | `merge-xcstrings.mjs`, key by key and rebranded; a key both sides changed keeps the fork's value and is listed |
   | anything else | left for a human |

   Then **`rebrand.mjs`** runs on both catalogs, so a Tinycast string upstream added where git merged
   cleanly says Redcast in the merge commit, before any gate builds it. The summary lists how many
   keys it renamed, and any exclusion whose key upstream deleted.

6. **Commit** `Merge upstream <old>..<new> (<n> commits)` with `Upstream-Sync: <sha>` and, after a
   re-anchor, `Upstream-Rewrite-Anchor: <sha>`.
7. **Gates**, unless `--skip-gates`: the Debug build (and its warnings in files the merge changed),
   `./Scripts/run-tests.sh` (each failure is rerun twice alone, then on pristine upstream in a
   temporary worktree; a harness that passes upstream is a regression, and so is a failing one that
   upstream's `run-tests.sh` does not list, since upstream would fail it as unknown;
   `form-input-test`, `onboarding-test` and `icon-cache-test` are reported, never fatal),
   `./Scripts/lint.sh`, the `Model/` purity grep, and the fork self-tests: `merge-xcstrings.mjs` and
   `rebrand.mjs --self-test`, and `rebrand.mjs --check`.
8. **Summary** in `build/sync/summary-<sha>.md` (also the PR body): the gates; what needs attention
   (files both sides changed, catalog keys to review, new upstream workflows to disable, changed rule
   docs, lines added to `docs/not-planned.md`, entitlement or usage-string changes, new harnesses);
   upstream's commits grouped by area with their PR links; the top 30 files by churn.

`TINYCAST_SYNC_XCODEGEN` replaces the `xcodegen` command (the self-test sets it to `true`, and puts
stand-in `xcodebuild`, `swiftlint` and `pnpm` first on its `PATH`), `TINYCAST_UPSTREAM_URL` the
upstream URL, and `TINYCAST_SYNC_KEEP=1` keeps the self-test's throwaway repositories for a look
after a failure.

### `Scripts/fork/merge-xcstrings.mjs`

`node Scripts/fork/merge-xcstrings.mjs [path]` reads the conflicted catalog's base, ours and theirs
from the index, merges them and stages the result. Per key, with the same rule for `sourceLanguage`
and `version`: equal sides win, a side equal to the base yields to the other, and a key both sides
changed merges its fields and languages one by one; what still differs keeps the fork's value and is
listed on stderr. Keys keep upstream's order, and a key only the fork has follows its predecessor in
the fork's order. All three sides are compared after `rebrand.mjs` has renamed them, so a key the
fork only rebranded takes upstream's edits, or goes when upstream deletes it, and the result says
Redcast throughout. The serializer, in `xcstrings.mjs`, writes Xcode's own layout, and `--self-test`
proves it by round-tripping the committed catalog byte for byte before running the merge fixtures,
a rebranded merge among them. Exit codes: 0 clean, 1 conflicts kept as ours, 2 unreadable input.

## Upstream workflows on the fork

The fork carries upstream's five workflows. Actions has never been enabled here; disable all five
first, because each would act on the fork:

| Workflow | What it would do here |
| --- | --- |
| `triage.yml` | closes every PR that links no approved issue, the sync PR included |
| `coauthors.yml` | flags PRs whose commits credit an AI co-author, which covers this fork's |
| `release.yml` | publishes releases and bumps a Homebrew tap under upstream's names |
| `website.yml`, `gitlab-mirror.yml` | guarded by upstream's repository name: a skipped run on every push |

```sh
for w in triage.yml coauthors.yml release.yml website.yml gitlab-mirror.yml; do
  gh workflow disable "$w" -R alesha-pro/redcast
done
```

The disabled state belongs to the workflow file, so upstream's edits to it keep it disabled. A new
upstream workflow starts enabled; the sync summary flags it with the command to disable it. Deleting or
guarding upstream's files would cost a conflict on every change upstream makes to them.

## Proposed: a nightly sync Action (not active)

Worth adding once the script has done three to five syncs by hand. It is kept here, not in
`.github/workflows/`, until then. A cheap Ubuntu job checks nightly whether upstream moved; only then
does a macOS job run the script, and a Linux job refresh one rolling PR (`sync/upstream`), a draft
while a gate fails. Public repositories run GitHub-hosted macOS jobs for free, and GitHub pauses
scheduled workflows after 60 days without activity. A failing run emails the token's owner: that is
the "needs a human" signal (a failed gate, exit 2 to 4, or a new upstream workflow).

It needs a fine-grained token, `FORK_SYNC_TOKEN`, on this repository only, with Contents, Pull
requests and **Workflows** read-write and a one-year expiry: `GITHUB_TOKEN` cannot push commits that
touch `.github/workflows/`, and upstream edits those. The token never reaches a job that runs
upstream's code. The macOS job merges and gates with `persist-credentials: false` and no write token,
and hands the merge to the next job as a `git bundle` artifact. Only the Linux `publish` job sees the
token, and it runs nothing from the repository: it fetches the bundle, pushes, and edits the PR. It
also refuses a sync that adds a workflow: once pushed with this token, that workflow would run on
the branch with the fork's secrets before anyone could disable it.

```yaml
name: Fork · upstream sync

# A cheap Linux check every night; the macOS merge and gates only when upstream has moved.
on:
  schedule:
    - cron: "23 3 * * *"
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: fork-sync
  cancel-in-progress: false

env:
  UPSTREAM_URL: https://github.com/abue-ammar/tinycast.git

jobs:
  check:
    if: github.repository == 'alesha-pro/redcast'
    runs-on: ubuntu-latest
    outputs:
      go: ${{ steps.check.outputs.go }}
    steps:
      - id: check
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
        run: |
          UP=$(git ls-remote "$UPSTREAM_URL" refs/heads/main | cut -f1)
          STATUS=$(gh api "repos/$REPO/compare/$UP...main" -q .status 2>/dev/null || echo unknown)
          PR_UP=$(gh pr view sync/upstream -R "$REPO" --json body -q .body 2>/dev/null \
            | sed -n 's/^Upstream-Sync: //p' | head -1)
          GO=true
          case "$STATUS" in ahead|identical) GO=false ;; esac
          [ "$PR_UP" = "$UP" ] && GO=false
          [ "${{ github.event_name }}" = workflow_dispatch ] && GO=true
          echo "upstream=$UP main=$STATUS pr=$PR_UP go=$GO"
          echo "go=$GO" >> "$GITHUB_OUTPUT"

  # Runs code upstream controls (build phases, harnesses, lint, pnpm), so it holds no write token.
  sync:
    needs: check
    if: needs.check.outputs.go == 'true'
    runs-on: macos-26
    timeout-minutes: 75
    outputs:
      status: ${{ steps.sync.outputs.status }}
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
          persist-credentials: false

      - name: Select Xcode 26
        run: |
          XCODE_PATH="$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -n1)"
          [ -n "$XCODE_PATH" ] || { ls /Applications | grep -i xcode; exit 1; }
          echo "DEVELOPER_DIR=$XCODE_PATH/Contents/Developer" >> "$GITHUB_ENV"

      - name: Tools
        run: brew install --quiet xcodegen swiftlint pnpm

      - name: Merge and gate
        id: sync
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git remote add upstream "$UPSTREAM_URL"
          mkdir -p "$RUNNER_TEMP/sync"
          set +e
          Scripts/fork/sync-upstream.sh --ci --branch sync/upstream \
            --summary "$RUNNER_TEMP/sync/summary.md"
          echo "status=$?" >> "$GITHUB_OUTPUT"
          [ -f "$RUNNER_TEMP/sync/summary.md" ] && cat "$RUNNER_TEMP/sync/summary.md" >> "$GITHUB_STEP_SUMMARY"
          exit 0

      - name: Bundle the merge
        if: steps.sync.outputs.status == '0' || steps.sync.outputs.status == '1'
        run: git bundle create "$RUNNER_TEMP/sync/sync.bundle" sync/upstream ^origin/main

      - uses: actions/upload-artifact@v7
        if: steps.sync.outputs.status == '0' || steps.sync.outputs.status == '1'
        with:
          name: sync
          path: ${{ runner.temp }}/sync/
          retention-days: 7

      - name: Ask for a human
        if: steps.sync.outputs.status != '0' && steps.sync.outputs.status != '1' && steps.sync.outputs.status != '10'
        run: exit 1

  # Holds the write token and runs nothing from the repository: git, gh and the bundle only.
  publish:
    needs: sync
    if: needs.sync.outputs.status == '0' || needs.sync.outputs.status == '1'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
          persist-credentials: false

      - uses: actions/download-artifact@v8
        with:
          name: sync
          path: ${{ runner.temp }}/sync

      - name: Publish the rolling PR
        env:
          GH_TOKEN: ${{ secrets.FORK_SYNC_TOKEN }}
          STATUS: ${{ needs.sync.outputs.status }}
        run: |
          git fetch -q "$RUNNER_TEMP/sync/sync.bundle" "+sync/upstream:refs/heads/sync/upstream"
          # Pushed with this token, a workflow upstream added would run with the fork's secrets.
          ADDED=$(git diff --no-renames --name-only --diff-filter=A origin/main sync/upstream \
            -- .github/workflows)
          if [ -n "$ADDED" ]; then
            echo "::error::upstream adds workflows; review them and push the sync by hand: $ADDED"
            exit 1
          fi
          gh auth setup-git
          git push --force-with-lease origin sync/upstream
          TITLE=$(head -1 "$RUNNER_TEMP/sync/summary.md" | sed 's/^# //')
          if gh pr view sync/upstream > /dev/null 2>&1; then
            gh pr edit sync/upstream --title "$TITLE" --body-file "$RUNNER_TEMP/sync/summary.md"
          else
            gh pr create --base main --head sync/upstream --title "$TITLE" \
              --body-file "$RUNNER_TEMP/sync/summary.md"
          fi
          # A failed gate keeps the PR as a draft and fails the run; green makes it ready.
          if [ "$STATUS" = 1 ]; then
            gh pr ready --undo sync/upstream || true
            exit 1
          fi
          gh pr ready sync/upstream || true
```

Rollout, in this order: disable the five workflows; create `FORK_SYNC_TOKEN` and note its expiry in
`FORK.md`; enable Actions once from the Actions tab; add the file as
`.github/workflows/fork-sync.yml` (a file of its own, so it never conflicts); run it with
`workflow_dispatch` and check the PR. Repository settings should allow "Create a merge commit". Keep
the token out of every other job and step.

### Manual sweep

1. `Scripts/fork/sync-upstream.sh --self-test` passes. It covers an advance, an already-merged
   upstream, a rewrite re-anchored, and an interleaved and a dropping rewrite refused. It resolves
   `project.pbxproj` and catalog conflicts, aborts an unknown conflict in CI and resumes one locally
   with `--continue`. It rebuilds a runtime both sides patched. Its gated runs, with stub runners on
   each side, check the harness triage. A flaky, an environmental and an upstream-too failure pass
   and are listed. A regression and a failing fork-only harness exit 1. Only warnings in merged
   files are reported. On rebranded catalogs, upstream's edit to a renamed line merges with nothing
   to review, and a string git merged cleanly is renamed in the merge commit and in the summary.
2. `node Scripts/fork/merge-xcstrings.mjs --self-test` and `node Scripts/fork/rebrand.mjs --self-test`
   pass, and `node Scripts/fork/rebrand.mjs --check` prints "nothing to rename" for both catalogs.
3. A real sync on a clean `main` ends with a summary whose gates are green, and its branch lands with
   `git merge --ff-only`.
