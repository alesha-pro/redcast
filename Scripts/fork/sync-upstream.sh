#!/bin/bash
# Merge upstream into a sync branch, resolve the generated files and run the gates. See FORK.md.
set -euo pipefail

cd "$(dirname "$0")/../.." || exit 4
ROOT="$PWD"
UPSTREAM_URL="${TINYCAST_UPSTREAM_URL:-https://github.com/abue-ammar/tinycast.git}"
UPSTREAM_WEB=https://github.com/abue-ammar/tinycast
FORK_REPO="${TINYCAST_FORK_REPO:-alesha-pro/redcast}"
XCODEGEN="${TINYCAST_SYNC_XCODEGEN:-xcodegen}"
WORK=build/sync
PBXPROJ=Tinycast.xcodeproj/project.pbxproj
RUNTIME=Tinycast/Resources/RaycastRuntime.generated.js
RUNTIME_SOURCES=Scripts/raycast-runtime
CATALOG=Tinycast/Resources/Localizable.xcstrings
INFO_CATALOG=Tinycast/Resources/InfoPlist.xcstrings
# The fork's own files: every sync keeps them as they are, whatever upstream did to its copy. The
# two GitHub files carried upstream's donation link and Discord; deleting them would conflict instead.
FORK_OWNED="README.md .github/FUNDING.yml .github/ISSUE_TEMPLATE/config.yml"
# Display- or load-bound: reported, never a reason to hold a sync back.
ENVIRONMENTAL=" form-input-test onboarding-test icon-cache-test "
RULE_DOCS=" AGENTS.md CLAUDE.md CONTRIBUTING.md docs/architecture.md docs/standards.md \
docs/testing.md docs/ui.md docs/development.md "

usage() {
    cat <<EOF
Usage: Scripts/fork/sync-upstream.sh [--branch NAME] [--skip-gates] [--summary FILE] [--ci]
       Scripts/fork/sync-upstream.sh --continue     # after resolving conflicts and git add
       Scripts/fork/sync-upstream.sh --self-test    # synthetic repos in \$TMPDIR, no network

Merges $UPSTREAM_URL main into sync/upstream-<sha> (--ci: the rolling
sync/upstream), re-anchoring on patch-equivalent commits when upstream rewrote its history. It
takes upstream's project.pbxproj and runtime bundle and regenerates both, merges the string
catalog key by key, keeps the fork's own files as they are, commits with an Upstream-Sync
trailer, runs the build, harnesses, lint and purity gates, and writes a markdown summary (default
build/sync/summary-<sha>.md).
The fork's own files: ${FORK_OWNED// /, }.

Exit codes: 0 merged, gates passed · 1 merged, a gate failed · 2 conflicts left ·
3 upstream rewrote history in a way that needs a human · 4 precondition failed ·
10 already up to date.
EOF
}

say() { printf '▸ %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die() {
    local code=$1
    shift
    printf '✗ %s\n' "$*" >&2
    exit "$code"
}

MODE=sync
NOTES=""
CATALOG_NOTE=""
TITLE=""
UNRESOLVED=""
BRANCH=""
SKIP_GATES=0
SUMMARY=""
CI=0
while [ $# -gt 0 ]; do
    case "$1" in
    --branch)
        [ $# -ge 2 ] || die 4 "--branch needs a name"
        BRANCH="$2"
        shift
        ;;
    --summary)
        [ $# -ge 2 ] || die 4 "--summary needs a path"
        SUMMARY="$2"
        shift
        ;;
    --skip-gates) SKIP_GATES=1 ;;
    --ci) CI=1 ;;
    --continue) MODE=continue ;;
    --self-test) MODE=self-test ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        die 4 "unknown option: $1"
        ;;
    esac
    shift
done

short() { printf '%s' "${1:0:7}"; }
has_word() { case "$1" in *" $2 "*) return 0 ;; esac; return 1; }

need() {
    command -v "$1" >/dev/null && return 0
    printf '✗ %s is missing: brew install %s\n' "$1" "$2" >&2
    MISSING=1
}

preconditions() {
    MISSING=0
    need git git
    need node node
    [ "$XCODEGEN" != xcodegen ] || need xcodegen xcodegen
    if [ "$SKIP_GATES" -eq 0 ]; then
        need swiftlint swiftlint
        command -v xcodebuild >/dev/null || {
            echo "✗ xcodebuild is missing: install Xcode" >&2
            MISSING=1
        }
    fi
    [ "$MISSING" -eq 0 ] || exit 4
    [ ! -e "$(git rev-parse --git-path MERGE_HEAD)" ] ||
        die 4 "a merge is in progress: finish it with --continue, or git merge --abort."
    [ -z "$(git status --porcelain --untracked-files=no)" ] ||
        die 4 "the working tree has changes; commit or stash them first."
    if [ -z "$BRANCH" ] && [ "$(git symbolic-ref --short -q HEAD || true)" != main ]; then
        die 4 "check out main first, or name the sync branch with --branch."
    fi
    git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
}

last_synced() {
    local trailer
    trailer="$(git log -n 300 --format='%(trailers:key=Upstream-Sync,valueonly)' HEAD |
        grep -m1 . | tr -d '[:space:]' || true)"
    if [ -n "$trailer" ] && git cat-file -e "$trailer^{commit}" 2>/dev/null; then
        printf '%s' "$trailer"
    elif git rev-parse -q --verify upstream/main >/dev/null &&
        git merge-base --is-ancestor upstream/main HEAD; then
        git rev-parse upstream/main
    fi
}

fetch() {
    say "Fetching upstream…"
    git fetch -q --no-tags upstream main
    # Tags feed `git describe`, which names the fork's builds.
    git fetch -q --tags --force upstream
    UP="$(git rev-parse upstream/main)"
}

# Upstream force-pushes; only a run of already-merged patches followed by new ones is provable.
detect_rewrite() {
    ANCHOR=""
    if git merge-base --is-ancestor "$OLD_UP" "$UP"; then return 0; fi
    local marks pattern dropped prefix='^=*[+]*$'
    marks="$(git rev-list --cherry-mark --right-only --no-merges --reverse --topo-order \
        "$OLD_UP...$UP")"
    dropped="$(git rev-list --cherry-mark --left-only --no-merges "$OLD_UP...$UP" |
        grep '^+' || true)"
    pattern="$(cut -c1 <<<"$marks" | tr -d '\n')"
    if [ -n "$dropped" ] || ! [[ "$pattern" =~ $prefix ]] || [[ "$pattern" != *=* ]]; then
        rewrite_summary "$marks" "$dropped"
        exit 3
    fi
    ANCHOR="$(grep '^=' <<<"$marks" | tail -1 | cut -c2-)"
    [[ "$pattern" == *+* ]] || ANCHOR="$UP"
    say "Upstream rewrote its history; re-anchoring on $(short "$ANCHOR")"
}

create_branch() {
    if [ -z "$BRANCH" ] && [ "$CI" -eq 1 ]; then BRANCH=sync/upstream; fi
    [ -n "$BRANCH" ] || BRANCH="sync/upstream-$(short "$UP")"
    if [ "$CI" -eq 1 ]; then
        git switch -q -C "$BRANCH"
    elif ! git switch -q -c "$BRANCH" 2>/dev/null; then
        die 4 "branch $BRANCH exists: delete it, or pass --branch."
    fi
}

anchor() {
    [ -n "$ANCHOR" ] || return 0
    git merge -q -s ours --no-ff -m "Record upstream's rewritten history up to $(short "$ANCHOR")" \
        -m "Upstream-Sync: $ANCHOR" "$ANCHOR"
}

# The keys a tool printed under its "renamed Tinycast" line, one quoted key per line.
renamed_keys() {
    awk '/renamed Tinycast in/ { keep = 1; next } keep && /^  "/ { sub(/^  /, ""); print; next }
        { keep = 0 }' <<<"$1" >>"$WORK/renamed-keys.txt"
}

# Both catalogs merge key by key whenever upstream changed one, conflicted or not. The fork renamed
# their Tinycast, so upstream's edits to those lines conflict; and where git merges on its own, an
# English value the fork derived from a key survives upstream rewording that key in place.
merge_catalog() {
    local path=$1 status=0 output summary
    output="$(node Scripts/fork/merge-xcstrings.mjs "$path" \
        2>>"$WORK/xcstrings-review.txt")" || status=$?
    [ "$status" -le 1 ] || return 1
    summary="$(head -1 <<<"$output")"
    note "merged $path key by key: $summary"
    CATALOG_NOTE="${CATALOG_NOTE:+$CATALOG_NOTE; }$(basename "$path" .xcstrings) $summary"
    renamed_keys "$output"
}

# Generated files take upstream's side and are rebuilt; the catalogs merge key by key; the fork's
# own files stay the fork's, whether git merged upstream's edit on its own or left a conflict.
resolve_known() {
    UNRESOLVED=""
    local path base
    : >"$WORK/xcstrings-review.txt"
    base="$(git merge-base HEAD MERGE_HEAD)"
    for path in "$CATALOG" "$INFO_CATALOG"; do
        git diff --quiet "$base" MERGE_HEAD -- "$path" && continue
        merge_catalog "$path" ||
            NOTES="${NOTES}- merge-xcstrings.mjs could not merge $path; it stays as git merged it"$'\n'
    done
    for path in $FORK_OWNED; do
        git diff --quiet "$base" MERGE_HEAD -- "$path" && continue
        git cat-file -e "HEAD:$path" 2>/dev/null || continue
        git checkout -q HEAD -- "$path"
        note "kept the fork's $path; upstream changed its own"
    done
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
        "$PBXPROJ" | "$RUNTIME")
            if git checkout -q --theirs -- "$path" 2>/dev/null; then
                git add -- "$path"
                note "took upstream's $path; regenerated below"
                continue
            fi
            ;;
        esac
        UNRESOLVED="$UNRESOLVED$path"$'\n'
    done < <(git diff --name-only --diff-filter=U)
}

merge_upstream() {
    [ "$ANCHOR" != "$UP" ] || return 0
    say "Merging upstream $(short "$UP")…"
    local output
    output="$(git merge -q --no-ff --no-commit "$UP" 2>&1)" || true
    [ -e "$(git rev-parse --git-path MERGE_HEAD)" ] ||
        die 4 "git merge did not start:"$'\n'"$output"
    resolve_known
    [ -z "$UNRESOLVED" ] && return 0
    if [ "$CI" -eq 1 ]; then
        git merge --abort
        conflict_summary
        die 2 "conflicts need a human; the merge was aborted:"$'\n'"$UNRESOLVED"
    fi
    save_state
    conflict_summary
    printf '✗ resolve these, git add them, then run Scripts/fork/sync-upstream.sh --continue:\n' >&2
    printf '%s' "$UNRESOLVED" | sed 's/^/  /' >&2
    exit 2
}

# Whatever the merges left saying Tinycast (a catalog merge-xcstrings could not take, a conflict
# resolved by hand) says Redcast in the merge commit, before any gate builds it.
rebrand_catalogs() {
    [ -e "$(git rev-parse --git-path MERGE_HEAD)" ] || return 0
    local output warnings
    if ! output="$(node Scripts/fork/rebrand.mjs 2>&1)"; then
        NOTES="${NOTES}- rebrand.mjs failed; the catalogs still say Tinycast: $output"$'\n'
        return 0
    fi
    if grep -q 'renamed Tinycast\|restored Tinycast' <<<"$output"; then
        note "$(grep 'renamed Tinycast\|restored Tinycast' <<<"$output" | tr '\n' ' ')"
    fi
    renamed_keys "$output"
    warnings="$(grep '^! ' <<<"$output" || true)"
    [ -z "$warnings" ] || NOTES="${NOTES}$(sed 's/^! /- rebrand.mjs: /' <<<"$warnings")"$'\n'

    local path
    for path in "$CATALOG" "$INFO_CATALOG"; do [ ! -e "$path" ] || git add -- "$path"; done
}

regenerate() {
    "$XCODEGEN" generate --quiet ||
        NOTES="${NOTES}- xcodegen failed; the project was not regenerated"$'\n'
    [ ! -d Tinycast.xcodeproj ] || git add -- Tinycast.xcodeproj
    # Upstream's bundle is right unless the fork patches the runtime sources it is built from.
    [ -d "$RUNTIME_SOURCES/src" ] || return 0
    git diff --quiet "$UP" HEAD -- "$RUNTIME_SOURCES/src" && return 0
    git diff --quiet "$BASE" "$UP" -- "$RUNTIME_SOURCES" "$RUNTIME" && return 0
    say "Rebuilding the extension runtime from the merged sources…"
    if command -v pnpm >/dev/null &&
        (cd "$RUNTIME_SOURCES" && pnpm install --frozen-lockfile --silent && node build.mjs); then
        git add -- "$RUNTIME"
    else
        NOTES="${NOTES}- the extension runtime did not rebuild: brew install pnpm, then rerun"$'\n'
    fi
}

commit_merge() {
    [ -e "$(git rev-parse --git-path MERGE_HEAD)" ] || return 0
    local count message noun=commits
    count="$(git rev-list --count --no-merges "$BASE..$UP")"
    [ "$count" != 1 ] || noun=commit
    TITLE="Merge upstream $(short "$BASE")..$(short "$UP") ($count $noun)"
    message="$TITLE"$'\n\n'"Upstream-Sync: $UP"
    [ -z "$ANCHOR" ] || message="$message"$'\n'"Upstream-Rewrite-Anchor: $ANCHOR"
    git commit -q -m "$message"
    ok "$TITLE"
}

STATE="$(git rev-parse --git-path tinycast-sync.state 2>/dev/null || echo .git/tinycast-sync.state)"

save_state() {
    local name
    for name in FORK_TIP OLD_UP UP BASE ANCHOR BRANCH SUMMARY SKIP_GATES CI CATALOG_NOTE; do
        printf '%s=%q\n' "$name" "${!name}"
    done >"$STATE"
}

GATE_BUILD=skipped GATE_TESTS=skipped GATE_LINT=skipped GATE_PURITY=skipped GATE_SELF=skipped
FLAKY="" IGNORED="" UPSTREAM_TOO="" REGRESSIONS="" FORK_ONLY="" WARNINGS=""

harness_gate() {
    if ./Scripts/run-tests.sh 2>&1 | tee "$WORK/tests.log"; then
        GATE_TESTS=pass
        return
    fi
    local failed name still="" upstream_harnesses
    failed="$(perl -pe 's/\e\[[0-9;]*m//g' "$WORK/tests.log" |
        sed -n 's/^FAILED .*harness(es) failed in [0-9]*s: //p' | tail -1)"
    if [ -z "$failed" ]; then
        GATE_TESTS=fail
        REGRESSIONS=" (the runner failed before reporting harnesses; see $WORK/tests.log)"
        return
    fi
    # Upstream's runner answers an unknown name with a failure, so a fork harness never goes there.
    upstream_harnesses=" $(harness_names "$UP" | tr '\n' ' ')"
    for name in $failed; do
        if ./Scripts/run-tests.sh "$name" >/dev/null 2>&1 ||
            ./Scripts/run-tests.sh "$name" >/dev/null 2>&1; then
            FLAKY="$FLAKY $name"
        elif has_word "$ENVIRONMENTAL" "$name"; then
            IGNORED="$IGNORED $name"
        elif ! has_word "$upstream_harnesses" "$name"; then
            FORK_ONLY="$FORK_ONLY $name"
        else
            still="$still $name"
        fi
    done
    if [ -n "$still" ]; then
        local tree="$WORK/upstream-wt"
        git worktree remove --force "$tree" >/dev/null 2>&1 || rm -rf "$tree"
        git worktree add -q --detach "$tree" "$UP"
        for name in $still; do
            if (cd "$tree" && ./Scripts/run-tests.sh "$name" >/dev/null 2>&1); then
                REGRESSIONS="$REGRESSIONS $name"
            else
                UPSTREAM_TOO="$UPSTREAM_TOO $name"
            fi
        done
        git worktree remove --force "$tree"
    fi
    if [ -n "$REGRESSIONS$FORK_ONLY" ]; then GATE_TESTS=fail; else GATE_TESTS=pass; fi
}

run_gates() {
    [ "$SKIP_GATES" -eq 0 ] || return 0
    say "Gate: Debug build…"
    if xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Debug \
        CODE_SIGNING_ALLOWED=NO -derivedDataPath "$WORK/DerivedData" build \
        >"$WORK/build.log" 2>&1; then GATE_BUILD=pass; else GATE_BUILD=fail; fi
    git diff --name-only "$FORK_TIP" HEAD >"$WORK/merged-files.txt"
    WARNINGS="$(grep ': warning: ' "$WORK/build.log" | sort -u | awk -v root="$ROOT/" '
        NR == FNR { changed[$0] = 1; next }
        { path = $0; sub(/:.*/, "", path)
          if (index(path, root) == 1) path = substr(path, length(root) + 1)
          if (path in changed) print }' "$WORK/merged-files.txt" - | head -20 || true)"
    say "Gate: harnesses…"
    harness_gate
    say "Gate: lint…"
    if ./Scripts/lint.sh >"$WORK/lint.log" 2>&1; then GATE_LINT=pass; else GATE_LINT=fail; fi
    if [ -z "$(grep -rln 'import AppKit\|import SwiftUI\|import Cocoa' Tinycast/Features/*/Model/ \
        2>/dev/null || true)" ]; then GATE_PURITY=pass; else GATE_PURITY=fail; fi
    if node Scripts/fork/merge-xcstrings.mjs --self-test >"$WORK/self-test.log" 2>&1 &&
        node Scripts/fork/rebrand.mjs --self-test >>"$WORK/self-test.log" 2>&1 &&
        node Scripts/fork/rebrand.mjs --check >>"$WORK/self-test.log" 2>&1; then
        GATE_SELF=pass
    else
        GATE_SELF=fail
    fi
}

gates_failed() {
    case " $GATE_BUILD $GATE_TESTS $GATE_LINT $GATE_PURITY $GATE_SELF " in
    *" fail "*) return 0 ;;
    esac
    return 1
}

mark() {
    case "$1" in pass) printf '✅' ;; fail) printf '❌' ;; *) printf '—' ;; esac
}

gates_line() {
    if [ "$SKIP_GATES" -eq 1 ]; then
        printf 'Gates: skipped (--skip-gates)'
        return
    fi
    printf 'Gates: build %s · harnesses %s' "$(mark "$GATE_BUILD")" "$(mark "$GATE_TESTS")"
    [ -z "$FLAKY" ] || printf ' (flaky:%s)' "$FLAKY"
    printf ' · lint %s · model purity %s · fork self-tests %s' "$(mark "$GATE_LINT")" \
        "$(mark "$GATE_PURITY")" "$(mark "$GATE_SELF")"
}

upstream_changed() { git diff --name-only "$BASE" "$UP"; }

harness_names() {
    git show "$1:Scripts/run-tests.sh" 2>/dev/null | awk '/^run / {
        for (i = 2; i <= NF; i++) if ($i !~ /^(-O|slow|exclusive|index)$/) { print $i; break } }' |
        sort -u
}

attention() {
    local both workflows rules declined capabilities harnesses review renamed count noun path
    both="$(comm -12 <(git diff --name-only "$OLD_UP" "$FORK_TIP" | sort) <(upstream_changed | sort) |
        { grep -vxF "$(tr ' ' '\n' <<<"$FORK_OWNED")" || true; } | tr '\n' ' ')"
    [ -z "$both" ] || printf -- '- Both sides changed: %s\n' "${both% }"
    for path in $FORK_OWNED; do
        git diff --quiet "$BASE" "$UP" -- "$path" ||
            printf -- "- Kept the fork's %s; upstream's change, to port by hand if it matters: %s\n" \
                "$path" "\`git diff $(short "$BASE") $(short "$UP") -- $path\`"
    done
    if [ -n "${CATALOG_NOTE:-}" ]; then
        review="$(head -10 "$WORK/xcstrings-review.txt" 2>/dev/null |
            sed -E 's/^(.*)  \((.*)\)$/"\1"(\2)/' | tr '\n' ' ' || true)"
        printf -- '- String catalogs: %s%s\n' "$CATALOG_NOTE" "${review:+: ${review% }}"
    fi
    renamed="$(awk '!seen[$0]++' "$WORK/renamed-keys.txt" 2>/dev/null || true)"
    if [ -n "$renamed" ]; then
        count="$(wc -l <<<"$renamed" | tr -d ' ')"
        if [ "$count" = 1 ]; then noun="string now says"; else noun="strings now say"; fi
        printf -- "- Rebrand: %s upstream %s Redcast; read each, and add one about" "$count" "$noun"
        printf -- ' upstream itself to EXCLUDED in Scripts/fork/rebrand.mjs, then rerun it: %s' \
            "$(head -20 <<<"$renamed" | paste -sd, - | sed 's/","/", "/g')"
        [ "$count" -le 20 ] || printf -- ' and %s more' "$((count - 20))"
        printf '\n'
    fi
    workflows="$(git diff --name-status "$BASE" "$UP" -- .github/workflows)"
    while IFS=$'\t' read -r status path; do
        [ -n "$path" ] || continue
        case "$status" in
        A*) printf -- '- Workflows: %s **added** → `gh workflow disable %s -R %s`\n' "$path" \
            "$(basename "$path")" "$FORK_REPO" ;;
        *) printf -- '- Workflows: %s %s (stays disabled)\n' "$path" "$status" ;;
        esac
    done <<<"$workflows"
    rules="$(upstream_changed | while IFS= read -r path; do
        if has_word "$RULE_DOCS" "$path"; then printf '%s ' "$path"; fi
    done)"
    [ -z "$rules" ] || printf -- '- Rules changed: %s(re-read before the next change)\n' "$rules"
    declined="$(git diff "$BASE" "$UP" -- docs/not-planned.md | grep -E '^\+[^+]' |
        sed 's/^+//' | grep -v '^[[:space:]]*$' | head -10 || true)"
    while IFS= read -r line; do
        [ -n "$line" ] && printf -- '- Declined upstream (docs/not-planned.md): "%s"\n' "$line"
    done <<<"$declined"
    capabilities="$(upstream_changed |
        grep -E '\.entitlements$|Info\.plist$|InfoPlist\.xcstrings$' | tr '\n' ' ' || true)"
    [ -z "$capabilities" ] || printf -- '- Capabilities: %s\n' "${capabilities% }"
    harnesses="$(comm -13 <(harness_names "$BASE") <(harness_names "$UP") | tr '\n' ' ')"
    [ -z "$harnesses" ] || printf -- '- New harnesses in run-tests.sh: %s\n' "${harnesses% }"
    [ -z "$REGRESSIONS" ] || printf -- '- Harness regressions (pass upstream):%s\n' "$REGRESSIONS"
    [ -z "$FORK_ONLY" ] || printf -- "- The fork's own harnesses failing:%s\n" "$FORK_ONLY"
    [ -z "$UPSTREAM_TOO" ] || printf -- '- Harnesses failing upstream too:%s\n' "$UPSTREAM_TOO"
    [ -z "$IGNORED" ] || printf -- '- Environmental harnesses failed (ignored):%s\n' "$IGNORED"
    [ "$GATE_BUILD" != fail ] || printf -- '- The Debug build failed: %s/build.log\n' "$WORK"
    [ "$GATE_LINT" != fail ] || printf -- '- Lint failed: %s/lint.log\n' "$WORK"
    if [ -n "$WARNINGS" ]; then
        printf -- '- Warnings in files the merge changed:\n'
        printf '%s\n' "$WARNINGS" | sed 's/^/  - /'
    fi
    printf '%s' "${NOTES:-}"
}

# The area is the path prefix most of a commit's files share.
commits_by_area() {
    local records area count
    records="$(git log --no-merges --format='@%h%x09%an%x09%s' --name-only "$BASE..$UP" |
        awk -F'\t' -v web="$UPSTREAM_WEB" '
        function area(path,   parts, n) {
            n = split(path, parts, "/")
            if (parts[1] == "Tinycast" && parts[2] == "Features" && n > 3) return parts[3]
            if (parts[1] == "Tinycast" && n > 2) return parts[2]
            return n > 1 ? parts[1] : "Repository"
        }
        function linked(text,   out, number) {
            out = ""
            while (match(text, /\(#[0-9]+\)/)) {
                number = substr(text, RSTART + 2, RLENGTH - 3)
                out = out substr(text, 1, RSTART - 1) "([#" number "](" web "/pull/" number "))"
                text = substr(text, RSTART + RLENGTH)
            }
            return out text
        }
        function flush(   best, name) {
            if (line == "") return
            best = ""
            for (name in counts) if (best == "" || counts[name] > counts[best] ||
                counts[name] == counts[best] && name < best) best = name
            print (best == "" ? "Repository" : best) "\t" line
            split("", counts)
            line = ""
        }
        /^@/ { flush(); line = "- " substr($1, 2) " " linked($3) " — " $2; next }
        NF { counts[area($0)]++ }
        END { flush() }')"
    [ -n "$records" ] || return 0
    cut -f1 <<<"$records" | sort | uniq -c | sort -k1,1nr -k2 | while read -r count area; do
        printf '### %s (%s)\n' "$area" "$count"
        awk -F'\t' -v area="$area" '$1 == area { print $2 }' <<<"$records"
        printf '\n'
    done | awk -v cap=200 '/^- / && ++listed > cap { skipped++; next } { print }
        END { if (skipped) printf "- … and %d more commits\n", skipped }'
}

diffstat() {
    git diff --numstat "$BASE" "$UP" | awk -F'\t' '{
        added = $1 == "-" ? 0 : $1; deleted = $2 == "-" ? 0 : $2
        print added + deleted "\t" added "\t" deleted "\t" $3 }' |
        sort -t$'\t' -k1,1nr | head -30 |
        awk -F'\t' '{ printf "- `%s` +%s −%s\n", $4, $2, $3 }'
}

summary_path() {
    [ -n "$SUMMARY" ] || SUMMARY="$WORK/summary-$(short "$UP").md"
    mkdir -p "$(dirname "$SUMMARY")"
}

write_summary() {
    summary_path
    local needs
    needs="$(attention)"
    {
        printf '# %s\n\nUpstream-Sync: %s\n' "$TITLE" "$UP"
        [ -z "$ANCHOR" ] || printf 'Upstream-Rewrite-Anchor: %s\n' "$ANCHOR"
        printf '%s\n\n## Needs attention\n' "$(gates_line)"
        printf '%s\n\n' "${needs:-Nothing.}"
        printf '## Commits by area\n'
        commits_by_area
        printf '## Diffstat (top 30 files)\n'
        diffstat
    } >"$SUMMARY"
    printf '\n%s\n%s\n' "$TITLE" "$(gates_line)"
    [ -z "$needs" ] || printf '%s\n' "$needs"
    note "summary: $SUMMARY"
}

conflict_summary() {
    summary_path
    {
        printf '# Merge upstream %s..%s: conflicts need a human\n\n' "$(short "$BASE")" \
            "$(short "$UP")"
        printf 'Upstream-Sync: %s\n\n## Conflicted files\n' "$UP"
        printf '%s' "$UNRESOLVED" | sed 's/^\(.*\)$/- `\1`/'
        printf '\n## Commits by area\n'
        commits_by_area
    } >"$SUMMARY"
    note "summary: $SUMMARY"
}

rewrite_summary() {
    TITLE="Upstream rewrote history that the fork already merged"
    summary_path
    {
        printf '# %s\n\nLast synced: %s\nUpstream now: %s\n\n' "$TITLE" "$OLD_UP" "$UP"
        printf 'Compare by hand: `git range-diff %s...%s`\n\n' "$OLD_UP" "$UP"
        printf '## Dropped or changed upstream (merged here, gone there)\n'
        if [ -n "$2" ]; then git log --no-walk --format='- %h %s' $(cut -c2- <<<"$2"); fi
        printf '\n## Upstream now (= already merged, + new), oldest first\n'
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            printf -- '- %s %s\n' "${line:0:1}" "$(git log -1 --format='%h %s' "${line:1}")"
        done <<<"$1"
    } >"$SUMMARY"
    printf '✗ %s; see %s\n' "$TITLE" "$SUMMARY" >&2
    cat "$SUMMARY" >&2
}

finish() {
    regenerate
    rebrand_catalogs
    commit_merge
    rm -f "$STATE"
    [ -n "${TITLE:-}" ] || TITLE="$(git log -1 --format=%s)"
    run_gates
    write_summary
    printf '\nNext: git switch main && git merge --ff-only %s && git push\n' "$BRANCH"
    if gates_failed; then exit 1; fi
    exit 0
}

sync() {
    preconditions
    mkdir -p "$WORK"
    : >"$WORK/renamed-keys.txt"
    FORK_TIP="$(git rev-parse HEAD)"
    OLD_UP="$(last_synced)"
    fetch
    [ -n "$OLD_UP" ] || OLD_UP="$(git merge-base HEAD "$UP" || true)"
    [ -n "$OLD_UP" ] || die 4 "this branch shares no history with upstream."
    if git merge-base --is-ancestor "$UP" HEAD; then
        ok "already up to date with upstream $(short "$UP")"
        exit 10
    fi
    detect_rewrite
    BASE="${ANCHOR:-$OLD_UP}"
    create_branch
    anchor
    merge_upstream
    finish
}

resume() {
    [ -f "$STATE" ] || die 4 "no sync to continue."
    # shellcheck source=/dev/null
    . "$STATE"
    local left
    left="$(git diff --name-only --diff-filter=U)"
    [ -z "$left" ] || die 2 "still conflicted:"$'\n'"$left"
    [ -e "$(git rev-parse --git-path MERGE_HEAD)" ] ||
        die 4 "no merge in progress; it was committed or aborted. Remove $STATE to start over."
    mkdir -p "$WORK"
    finish
}

commit_file() {
    mkdir -p "$(dirname "$1/$2")"
    printf '%s\n' "$3" >"$1/$2"
    git -C "$1" add -- "$2"
    git -C "$1" commit -q -m "$4"
}

new_case() {
    CASE="$TEST_ROOT/$1" UPR="$TEST_ROOT/$1/upstream" FORK="$TEST_ROOT/$1/fork"
    git init -q -b main "$UPR"
    commit_file "$UPR" README "base" "Base"
    commit_file "$UPR" "$PBXPROJ" "project" "Add the project"
    git clone -q "$UPR" "$FORK"
    git -C "$FORK" remote rename origin upstream
    mkdir -p "$FORK/Scripts/fork"
    cp "$ROOT/Scripts/fork/sync-upstream.sh" "$ROOT/Scripts/fork/"*.mjs "$FORK/Scripts/fork/"
    git -C "$FORK" add Scripts
    git -C "$FORK" commit -q -m "Add the fork's scripts"
    commit_file "$FORK" fork.txt "fork" "Fork work"
}

# `--gates` runs them against the stand-in tools on the self-test's PATH.
run_sync() {
    local status=0 gates=--skip-gates
    if [ "${1:-}" = --gates ]; then gates="" && shift; fi
    (cd "$FORK" && PATH="$TEST_ROOT/bin:$PATH" ./Scripts/fork/sync-upstream.sh \
        ${gates:+"$gates"} "$@") >"$CASE/out.log" 2>&1 || status=$?
    printf '%s' "$status"
}

land() { git -C "$FORK" switch -q main && git -C "$FORK" merge -q --ff-only "$1"; }

check() {
    local message=$1
    shift
    if "$@"; then
        PASSES=$((PASSES + 1))
    else
        FAILURES=$((FAILURES + 1))
        printf 'FAIL: %s\n' "$message"
        sed 's/^/    /' "$CASE/out.log" 2>/dev/null || true
    fi
}

trailer() { git -C "$FORK" log -1 --format="%(trailers:key=$1,valueonly)" | tr -d '[:space:]'; }

# Three upstream commits, merged into the fork by a first sync and landed on main.
merged_three() {
    new_case "$1"
    BEFORE="$(git -C "$UPR" rev-parse HEAD)"
    commit_file "$UPR" one.txt 1 "One"
    commit_file "$UPR" two.txt 2 "Two"
    commit_file "$UPR" three.txt 3 "Three"
    local status up
    up="$(git -C "$UPR" rev-parse HEAD)"
    status="$(run_sync)"
    check "$1: the first sync merges (exit $status)" [ "$status" = 0 ]
    land "sync/upstream-${up:0:7}"
    git -C "$UPR" reset -q --hard "$BEFORE"
}

# A force-push replays a merged commit's patch as a new commit.
replay() {
    git -C "$UPR" cherry-pick "$(git -C "$FORK" log --format=%H -1 --grep="^$1\$" HEAD)" >/dev/null
    git -C "$UPR" commit -q --amend -m "$1 (rewritten)"
}

self_test() {
    TEST_ROOT="${TMPDIR:-/tmp}"
    TEST_ROOT="${TEST_ROOT%/}/tinycast-sync-selftest-$(uuidgen)"
    mkdir -p "$TEST_ROOT"
    [ -n "${TINYCAST_SYNC_KEEP:-}" ] || trap 'rm -rf "$TEST_ROOT"' EXIT
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TINYCAST_SYNC_XCODEGEN=true
    export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
    export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
    export GIT_EDITOR=true GIT_MERGE_AUTOEDIT=no
    PASSES=0 FAILURES=0
    local status up base summary
    stub_tools

    new_case advance
    commit_file "$UPR" up.txt "upstream" "Upstream work (#12)"
    up="$(git -C "$UPR" rev-parse HEAD)"
    status="$(run_sync)"
    check "an advance merges (exit $status)" [ "$status" = 0 ]
    check "the merge carries the Upstream-Sync trailer" [ "$(trailer Upstream-Sync)" = "$up" ]
    check "both sides land" test -f "$FORK/up.txt" -a -f "$FORK/fork.txt"
    check "the summary links upstream's PR" \
        grep -q "pull/12" "$FORK/build/sync/summary-${up:0:7}.md"
    land "sync/upstream-${up:0:7}"
    status="$(run_sync)"
    check "an already merged upstream exits 10 (got $status)" [ "$status" = 10 ]

    merged_three rewrite
    replay One && replay Two && replay Three
    base="$(git -C "$UPR" rev-parse HEAD)"
    commit_file "$UPR" four.txt 4 "Four"
    commit_file "$UPR" five.txt 5 "Five"
    status="$(run_sync)"
    check "a rewrite of merged commits plus new ones merges (exit $status)" [ "$status" = 0 ]
    check "the merge names its anchor" [ "$(trailer Upstream-Rewrite-Anchor)" = "$base" ]
    check "the new commits land" test -f "$FORK/four.txt" -a -f "$FORK/five.txt"
    check "and only they are counted" grep -q "(2 commits)" "$CASE/out.log"

    merged_three interleaved
    commit_file "$UPR" new1.txt n "New one"
    replay One && replay Two && replay Three
    commit_file "$UPR" new2.txt n "New two"
    status="$(run_sync)"
    check "an interleaved rewrite needs a human (exit $status)" [ "$status" = 3 ]

    merged_three dropped
    replay One && replay Three
    status="$(run_sync)"
    check "a dropped merged commit needs a human (exit $status)" [ "$status" = 3 ]
    check "and the dropped commit is named" grep -q "Two" "$CASE/out.log"

    new_case project
    commit_file "$FORK" "$PBXPROJ" "project (fork)" "Fork's project"
    commit_file "$UPR" "$PBXPROJ" "project (upstream)" "Upstream's project"
    status="$(run_sync)"
    check "a project.pbxproj conflict resolves (exit $status)" [ "$status" = 0 ]
    check "to upstream's side, before regenerating" grep -qx "project (upstream)" "$FORK/$PBXPROJ"

    new_case catalog
    catalog_case
    status="$(run_sync)"
    check "a catalog conflict merges key by key (exit $status)" [ "$status" = 0 ]
    check "keeping both new keys in order" [ "$(grep -o '"[A-Z]" :' "$FORK/$CATALOG" |
        tr -d ' :"\n')" = "ACBZ" ]

    new_case ci
    commit_file "$FORK" a.txt "fork" "Fork's a"
    commit_file "$UPR" a.txt "upstream" "Upstream's a"
    status="$(run_sync --ci)"
    check "an unknown conflict in CI exits 2 (got $status)" [ "$status" = 2 ]
    check "with the merge aborted" [ ! -e "$FORK/.git/MERGE_HEAD" ]
    check "on the rolling branch" [ "$(git -C "$FORK" symbolic-ref --short HEAD)" = sync/upstream ]

    new_case resume
    commit_file "$FORK" a.txt "fork" "Fork's a"
    commit_file "$UPR" a.txt "upstream" "Upstream's a"
    up="$(git -C "$UPR" rev-parse HEAD)"
    status="$(run_sync)"
    check "an unknown conflict stops for a human (exit $status)" [ "$status" = 2 ]
    check "with the merge left in progress" [ -e "$FORK/.git/MERGE_HEAD" ]
    printf 'both\n' >"$FORK/a.txt"
    git -C "$FORK" add a.txt
    status="$(run_sync --continue)"
    check "--continue finishes it (exit $status)" [ "$status" = 0 ]
    check "with the trailer" [ "$(trailer Upstream-Sync)" = "$up" ]

    new_case gates
    gates_case "shared-test upstream-broken-test form-input-test flaky-test" \
        "upstream-broken-test fail"$'\n'"form-input-test fail" \
        "shared-test upstream-broken-test form-input-test flaky-test fork-test" \
        "upstream-broken-test fail"$'\n'"form-input-test fail"$'\n'"flaky-test flaky"
    up="$(git -C "$UPR" rev-parse HEAD)"
    status="$(run_sync --gates)"
    summary="$FORK/build/sync/summary-${up:0:7}.md"
    check "failures that are not the fork's pass the gates (exit $status)" [ "$status" = 0 ]
    check "a harness that passes alone is flaky" grep -q "(flaky: flaky-test)" "$summary"
    check "one failing upstream too is listed" \
        grep -q "failing upstream too: upstream-broken-test$" "$summary"
    check "an environmental one is ignored" grep -q "(ignored): form-input-test$" "$summary"
    check "a warning in a merged file is listed" grep -q "merged.swift:1:1: warning" "$summary"
    check "and one in an untouched file is not" sh -c '! grep -q kept.swift "$1"' - "$summary"

    new_case regression
    gates_case "shared-test" "" "shared-test" "shared-test fail"
    up="$(git -C "$UPR" rev-parse HEAD)"
    status="$(run_sync --gates)"
    summary="$FORK/build/sync/summary-${up:0:7}.md"
    check "a harness that passes upstream and fails here fails the gates (exit $status)" \
        [ "$status" = 1 ]
    check "as a regression" grep -q "(pass upstream): shared-test$" "$summary"

    new_case fork-harness
    gates_case "shared-test" "" "shared-test fork-test" "fork-test fail"
    up="$(git -C "$UPR" rev-parse HEAD)"
    status="$(run_sync --gates)"
    summary="$FORK/build/sync/summary-${up:0:7}.md"
    check "a failing harness upstream lacks fails the gates (exit $status)" [ "$status" = 1 ]
    check "and is listed as the fork's" grep -q "own harnesses failing: fork-test$" "$summary"

    new_case runtime
    runtime_case
    status="$(run_sync)"
    check "a runtime the fork patches merges (exit $status)" [ "$status" = 0 ]
    check "and is rebuilt from both sides' sources" \
        [ "$(git -C "$FORK" show "HEAD:$RUNTIME")" = "A B" ]

    new_case rebrand
    rebrand_case
    up="$(git -C "$UPR" rev-parse HEAD)"
    status="$(run_sync)"
    check "upstream's edit to a string the fork renamed merges (exit $status)" [ "$status" = 0 ]
    check "taking upstream's wording, renamed" \
        git -C "$FORK" grep -q '"value" : "Redcast schließen"' HEAD -- "$CATALOG"
    check "a string it adds there arrives renamed" \
        git -C "$FORK" grep -q '"value" : "About Redcast"' HEAD -- "$CATALOG"
    check "with nothing to review" grep -q "+1 upstream keys, -0 removed, 0 need review" \
        "$CASE/out.log"
    check "one git merges on its own is merged key by key too" \
        grep -q "+2 upstream keys, -1 removed, 0 need review" "$CASE/out.log"
    check "so a string upstream adds there arrives renamed" \
        git -C "$FORK" grep -q '"value" : "Redcast filmt."' HEAD -- "$INFO_CATALOG"
    check "and a key it rewords in place takes English from its new text" \
        git -C "$FORK" grep -q '"value" : "Redcast backup"' HEAD -- "$INFO_CATALOG"
    check "dropping the old key's" \
        sh -c '! git -C "$1" grep -q "Backup\"" HEAD -- "$2"' - "$FORK" "$INFO_CATALOG"
    summary="$FORK/build/sync/summary-${up:0:7}.md"
    check "the summary names every upstream string renamed" \
        grep -q 'Rebrand: 4 upstream strings now say Redcast.*"About Tinycast".*"Tinycast backup"' \
        "$summary"
    check "leaving a clean tree" [ -z "$(git -C "$FORK" status --porcelain --untracked-files=no)" ]

    new_case readme
    readme_case
    up="$(git -C "$UPR" rev-parse HEAD)"
    status="$(run_sync)"
    check "an upstream README.md edit git would merge on its own syncs (exit $status)" \
        [ "$status" = 0 ]
    check "keeping the fork's README.md as it was" \
        [ "$(git -C "$FORK" show HEAD:README.md)" = "$FORK_README" ]
    check "while the rest of upstream's commit lands" test -f "$FORK/up.txt"
    check "and the summary names upstream's change" \
        grep -q "Kept the fork's README.md.*git diff" "$FORK/build/sync/summary-${up:0:7}.md"
    check "once, not again under both sides changed" \
        sh -c '! grep -q "Both sides changed:.*README.md" "$1"' - "$FORK/build/sync/summary-${up:0:7}.md"
    land "sync/upstream-${up:0:7}"
    commit_file "$UPR" README.md "# Tinycast, renamed"$'\n\n'"A launcher." "Upstream retitles its README"
    status="$(run_sync)"
    check "one that conflicts syncs too (exit $status)" [ "$status" = 0 ]
    check "with the fork's README.md kept" \
        [ "$(git -C "$FORK" show HEAD:README.md)" = "$FORK_README" ]

    printf '%d passed, %d failed\n' "$PASSES" "$FAILURES"
    [ "$FAILURES" -eq 0 ] || exit 1
    ok "sync-upstream self-test passed"
}

catalog_entries() {
    printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n'
    local key first=1
    for key in "$@"; do
        [ "$first" -eq 1 ] || printf ',\n'
        printf '    "%s" : {\n\n    }' "$key"
        first=0
    done
    printf '\n  },\n  "version" : "1.0"\n}\n'
}

catalog_case() {
    mkdir -p "$UPR/$(dirname "$CATALOG")" "$FORK/$(dirname "$CATALOG")"
    catalog_entries A Z >"$UPR/$CATALOG"
    git -C "$UPR" add -A && git -C "$UPR" commit -q -m "Add the catalog"
    git -C "$FORK" pull -q --no-rebase --no-edit upstream main
    catalog_entries A C Z >"$FORK/$CATALOG"
    git -C "$FORK" commit -q -am "Fork's string"
    catalog_entries A B Z >"$UPR/$CATALOG"
    git -C "$UPR" commit -q -am "Upstream's string"
}

# Xcode's layout of a one-language entry, for the catalogs the rebrand case edits.
german_entry() {
    printf '    "%s" : {\n      "localizations" : {\n        "de" : {\n' "$1"
    printf '          "stringUnit" : {\n            "state" : "translated",\n'
    printf '            "value" : "%s"\n          }\n        }\n      }\n    }' "$2"
}

catalog_of() {
    printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n'
    local first=1
    while [ $# -gt 1 ]; do
        [ "$first" -eq 1 ] || printf ',\n'
        german_entry "$1" "$2"
        first=0
        shift 2
    done
    printf '\n  },\n  "version" : "1.0"\n}\n'
}

# The fork renames both catalogs. Upstream edits a renamed line in one, so that one conflicts. In
# the other it adds a string and rewords a key in place, both away from the renamed lines, which
# git merges on its own, keeping the English the fork gave the old key under the new one.
rebrand_case() {
    mkdir -p "$UPR/$(dirname "$CATALOG")"
    catalog_of "Quit Tinycast" "Tinycast beenden" >"$UPR/$CATALOG"
    catalog_of NSMicrophoneUsageDescription "Tinycast nimmt auf." \
        "Tinycast Backup" "Tinycast-Sicherung" >"$UPR/$INFO_CATALOG"
    git -C "$UPR" add -A && git -C "$UPR" commit -q -m "Add the catalogs"
    git -C "$FORK" pull -q --no-rebase --no-edit upstream main
    (cd "$FORK" && node Scripts/fork/rebrand.mjs >/dev/null 2>&1)
    git -C "$FORK" commit -q -am "Rebrand"
    catalog_of "About Tinycast" "Über Tinycast" "Quit Tinycast" "Tinycast schließen" \
        >"$UPR/$CATALOG"
    catalog_of NSCameraUsageDescription "Tinycast filmt." \
        NSMicrophoneUsageDescription "Tinycast nimmt auf." \
        "Tinycast backup" "Tinycast-Sicherung" >"$UPR/$INFO_CATALOG"
    git -C "$UPR" commit -q -am "Upstream's strings"
}

# Upstream's README.md, the fork's own rewrite of its title, then an upstream commit that edits its
# last line, away from the fork's, and adds a file: git would merge the README on its own.
readme_case() {
    commit_file "$UPR" README.md "# Tinycast"$'\n\n'"A launcher."$'\n\n'"Install with Homebrew." \
        "Upstream's README"
    git -C "$FORK" pull -q --no-rebase --no-edit upstream main
    FORK_README="# Redcast"$'\n\n'"A launcher."$'\n\n'"Install with Homebrew."
    commit_file "$FORK" README.md "$FORK_README" "The fork's README"
    printf 'upstream\n' >"$UPR/up.txt"
    printf '%s\n' "# Tinycast"$'\n\n'"A launcher."$'\n\n'"Install with Homebrew or a DMG." \
        >"$UPR/README.md"
    git -C "$UPR" add -A && git -C "$UPR" commit -q -m "Upstream edits its README"
}

# The gates' tools, and pnpm for the runtime rebuild: none of them may reach Xcode or the network.
stub_tools() {
    mkdir -p "$TEST_ROOT/bin"
    {
        printf '#!/bin/sh\n'
        printf 'echo "$PWD/%s.swift:1:1: warning: stub"\n' merged kept
    } >"$TEST_ROOT/bin/xcodebuild"
    printf '#!/bin/sh\nexit 0\n' >"$TEST_ROOT/bin/swiftlint"
    printf '#!/bin/sh\nexit 0\n' >"$TEST_ROOT/bin/pnpm"
    chmod +x "$TEST_ROOT/bin/"*
}

# A run-tests.sh that knows the named harnesses; Tests/results fails one, or flakes it in the suite.
runner_stub() {
    cat <<'EOF'
#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
only="${1:-}" failed="" ran=0
run() {
    [ -z "$only" ] || [ "$1" = "$only" ] || return 0
    ran=$((ran + 1))
    case "$(sed -n "s/^$1 //p" Tests/results)" in
    fail) failed="$failed $1" ;;
    flaky) [ -n "$only" ] || failed="$failed $1" ;;
    esac
}
EOF
    printf 'run %s\n' "$@"
    cat <<'EOF'
[ "$ran" -gt 0 ] || { echo "No harness named '$only'." >&2; exit 2; }
[ -z "$failed" ] || { echo "FAILED  harness(es) failed in 0s:$failed" >&2; exit 1; }
echo "PASSED"
EOF
}

# Upstream's runner and results, then the fork's own, then an upstream change to merged.swift.
gates_case() {
    mkdir -p "$UPR/Scripts" "$UPR/Tests" "$UPR/$(dirname "$CATALOG")"
    # shellcheck disable=SC2086
    runner_stub $1 >"$UPR/Scripts/run-tests.sh"
    printf '#!/bin/sh\necho "lint-clean"\n' >"$UPR/Scripts/lint.sh"
    chmod +x "$UPR/Scripts/run-tests.sh" "$UPR/Scripts/lint.sh"
    printf '%s\n' "$2" >"$UPR/Tests/results"
    catalog_entries A Z >"$UPR/$CATALOG"
    printf 'kept\n' >"$UPR/kept.swift"
    git -C "$UPR" add -A && git -C "$UPR" commit -q -m "Add the runner"
    git -C "$FORK" pull -q --no-rebase --no-edit upstream main
    # shellcheck disable=SC2086
    runner_stub $3 >"$FORK/Scripts/run-tests.sh"
    printf '%s\n' "$4" >"$FORK/Tests/results"
    git -C "$FORK" commit -q -am "Fork's harnesses"
    commit_file "$UPR" merged.swift "merged" "Upstream's change"
}

# Both sides patch one runtime source each and rebuild; the bundles conflict.
runtime_case() {
    local sources="$UPR/$RUNTIME_SOURCES"
    mkdir -p "$sources/src" "$UPR/$(dirname "$RUNTIME")"
    cat >"$sources/build.mjs" <<'EOF'
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
const parts = readdirSync("src").sort().map((name) => readFileSync(`src/${name}`, "utf8").trim());
writeFileSync("../../Tinycast/Resources/RaycastRuntime.generated.js", `${parts.join(" ")}\n`);
EOF
    printf 'a\n' >"$sources/src/a.js"
    printf 'b\n' >"$sources/src/b.js"
    printf 'a b\n' >"$UPR/$RUNTIME"
    git -C "$UPR" add -A && git -C "$UPR" commit -q -m "Add the runtime"
    git -C "$FORK" pull -q --no-rebase --no-edit upstream main
    printf 'A\n' >"$FORK/$RUNTIME_SOURCES/src/a.js"
    printf 'A b\n' >"$FORK/$RUNTIME"
    git -C "$FORK" commit -q -am "Fork's runtime patch"
    printf 'B\n' >"$sources/src/b.js"
    printf 'a B\n' >"$UPR/$RUNTIME"
    git -C "$UPR" commit -q -am "Upstream's runtime change"
}

case "$MODE" in
sync) sync ;;
continue) resume ;;
self-test) self_test ;;
esac
