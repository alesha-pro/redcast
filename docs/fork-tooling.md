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
- **`sync-upstream.sh` never pushes and never guesses.** It merges into a branch of its own, resolves
  only the three files whose resolution is mechanical, and stops on anything else. When upstream
  rewrote history it re-anchors only on commits it can prove are already merged.
- **A sync branch lands by fast-forward or a merge commit, never squash or rebase.** Either drops
  upstream's ancestry, and the next sync would replay everything.

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

`TINYCAST_LSREGISTER` replaces the `lsregister` binary, so the swap, rollback and detach can be
rehearsed on a scratch `TINYCAST_INSTALL_PATH` without touching LaunchServices.

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
   | `Tinycast/Resources/Localizable.xcstrings` | `merge-xcstrings.mjs`, key by key; a key both sides changed keeps the fork's value and is listed |
   | anything else | left for a human |

6. **Commit** `Merge upstream <old>..<new> (<n> commits)` with `Upstream-Sync: <sha>` and, after a
   re-anchor, `Upstream-Rewrite-Anchor: <sha>`.
7. **Gates**, unless `--skip-gates`: the Debug build (and its warnings in files the merge changed),
   `./Scripts/run-tests.sh` (each failure is rerun twice alone, then on pristine upstream in a
   temporary worktree; a harness that passes upstream is a regression, and so is a failing one that
   upstream's `run-tests.sh` does not list, since upstream would fail it as unknown;
   `form-input-test`, `onboarding-test` and `icon-cache-test` are reported, never fatal),
   `./Scripts/lint.sh`, the `Model/` purity grep, and `merge-xcstrings.mjs --self-test`.
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
the fork's order. The serializer writes Xcode's own layout, and `--self-test` proves it by
round-tripping the committed catalog byte for byte before running the merge fixtures. Exit codes:
0 clean, 1 conflicts kept as ours, 2 unreadable input.

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
  gh workflow disable "$w" -R alesha-pro/tinycast
done
```

The disabled state belongs to the workflow file, so upstream's edits to it keep it disabled. A new
upstream workflow starts enabled; the sync summary flags it with the command to disable it. Deleting or
guarding upstream's files would cost a conflict on every change upstream makes to them.

## Proposed: a nightly sync Action (not active)

Worth adding once the script has done three to five syncs by hand. It is kept here, not in
`.github/workflows/`, until then. A cheap Ubuntu job checks nightly whether upstream moved; only then
does a macOS job run the script and refresh one rolling PR (`sync/upstream`), a draft while a gate
fails. Public repositories run GitHub-hosted macOS jobs for free, and GitHub pauses scheduled
workflows after 60 days without activity. A failing run emails the token's owner: that is the "needs
a human" signal (exit 2 or 3).

It needs a fine-grained token, `FORK_SYNC_TOKEN`, on this repository only, with Contents, Pull
requests and **Workflows** read-write and a one-year expiry: `GITHUB_TOKEN` cannot push commits that
touch `.github/workflows/`, and upstream edits those.

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
    if: github.repository == 'alesha-pro/tinycast'
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

  sync:
    needs: check
    if: needs.check.outputs.go == 'true'
    runs-on: macos-26
    timeout-minutes: 75
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
          token: ${{ secrets.FORK_SYNC_TOKEN }}

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
          set +e
          Scripts/fork/sync-upstream.sh --ci --branch sync/upstream --summary "$RUNNER_TEMP/summary.md"
          echo "status=$?" >> "$GITHUB_OUTPUT"
          [ -f "$RUNNER_TEMP/summary.md" ] && cat "$RUNNER_TEMP/summary.md" >> "$GITHUB_STEP_SUMMARY"
          exit 0

      - name: Publish the rolling PR
        if: steps.sync.outputs.status == '0' || steps.sync.outputs.status == '1'
        env:
          GH_TOKEN: ${{ secrets.FORK_SYNC_TOKEN }}
        run: |
          git push --force-with-lease origin sync/upstream
          TITLE=$(head -1 "$RUNNER_TEMP/summary.md" | sed 's/^# //')
          if gh pr view sync/upstream > /dev/null 2>&1; then
            gh pr edit sync/upstream --title "$TITLE" --body-file "$RUNNER_TEMP/summary.md"
          else
            gh pr create --base main --head sync/upstream --title "$TITLE" \
              --body-file "$RUNNER_TEMP/summary.md"
          fi
          # A failed gate keeps the PR as a draft; green makes it ready.
          if [ "${{ steps.sync.outputs.status }}" = 1 ]; then gh pr ready --undo sync/upstream || true
          else gh pr ready sync/upstream || true; fi

      - name: Ask for a human
        if: steps.sync.outputs.status != '0' && steps.sync.outputs.status != '10'
        run: exit 1
```

Rollout, in this order: disable the five workflows; create `FORK_SYNC_TOKEN` and note its expiry in
`FORK.md`; enable Actions once from the Actions tab; add the file as
`.github/workflows/fork-sync.yml` (a file of its own, so it never conflicts); run it with
`workflow_dispatch` and check the PR. Repository settings should allow "Create a merge commit".

### Manual sweep

1. `Scripts/fork/sync-upstream.sh --self-test` passes. It covers an advance, an already-merged
   upstream, a rewrite re-anchored, and an interleaved and a dropping rewrite refused. It resolves
   `project.pbxproj` and catalog conflicts, aborts an unknown conflict in CI and resumes one locally
   with `--continue`. It rebuilds a runtime both sides patched. Its gated runs, with stub runners on
   each side, check the harness triage. A flaky, an environmental and an upstream-too failure pass
   and are listed. A regression and a failing fork-only harness exit 1. Only warnings in merged
   files are reported.
2. `node Scripts/fork/merge-xcstrings.mjs --self-test` passes.
3. A real sync on a clean `main` ends with a summary whose gates are green, and its branch lands with
   `git merge --ff-only`.
