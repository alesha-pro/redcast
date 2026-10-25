#!/bin/bash
# Build the fork in Release, sign it, and swap it into /Applications. See FORK.md.
set -euo pipefail

cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD"
SELF="$ROOT/Scripts/fork/install.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BUNDLE_ID="${TINYCAST_FORK_BUNDLE_ID:-io.redcast.app}"
# The fork's id before Redcast had its own: a copy under it is this fork, replaced and migrated.
LEGACY_ID="${TINYCAST_FORK_LEGACY_ID:-com.tinycast.app.fork}"
APP_NAME=Redcast
DEST="${TINYCAST_INSTALL_PATH:-/Applications/$APP_NAME.app}"
PARENT="$(dirname "$DEST")"
NAME="$(basename "$DEST" .app)"
# Where the fork lived before it was Redcast: a fork copy there is migrated, any other left alone.
LEGACY="$PARENT/Tinycast.app"
WORK="$ROOT/build/fork"
# No `.app` suffix, so LaunchServices never registers the kept copy.
PREVIOUS="$WORK/Tinycast.previous"
# The path the kept copy was installed at, so --rollback after a migration restores the old name.
PREVIOUS_ORIGIN="$WORK/Tinycast.previous.origin"
INSTALLED=""
FRAMEWORKS=/System/Library/Frameworks/CoreServices.framework/Frameworks
LSREGISTER="${TINYCAST_LSREGISTER:-$FRAMEWORKS/LaunchServices.framework/Support/lsregister}"

usage() {
    cat <<EOF
Usage: Scripts/fork/install.sh [--no-launch] [--force-quit] [--accept-new-identity]
       Scripts/fork/install.sh --rollback [--no-launch] [--force-quit]
       Scripts/fork/install.sh --self-check
       Scripts/fork/install.sh --self-test     # stubbed installs into \$TMPDIR, one from a fake app

Builds the fork in Release for this Mac as $APP_NAME.app, signs it with the one Apple Development
identity, verifies it, quits the installed copy gracefully and swaps the new one into place by
rename. A fork copy still named Tinycast.app beside it is migrated: it goes to the rollback slot.

  --no-launch            do not reopen the app after the swap
  --force-quit           SIGTERM, then SIGKILL, when the app does not quit within 20 s
  --accept-new-identity  install although the code requirement changes (TCC grants need re-granting)
  --rollback             put back the copy the last install replaced (build/fork/Tinycast.previous)
  --self-check           resolve identity, version and paths, and list what an install would do;
                         builds, quits, moves and registers nothing

Environment: TINYCAST_SIGN_IDENTITY, TINYCAST_FORK_BUNDLE_ID ($BUNDLE_ID),
TINYCAST_INSTALL_PATH ($DEST), DEVELOPER_DIR.

Exit codes: 0 installed · 1 build or verification failed · 2 refused · 3 quit timed out ·
4 swap failed and was rolled back · 64 usage.
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

MODE=install
LAUNCH=1
FORCE_QUIT=0
ACCEPT_NEW=0
DETACHED=0
ARGS=("$@")
STAGE=""
while [ $# -gt 0 ]; do
    case "$1" in
    --no-launch) LAUNCH=0 ;;
    --force-quit) FORCE_QUIT=1 ;;
    --accept-new-identity) ACCEPT_NEW=1 ;;
    --rollback) MODE=rollback ;;
    --self-check) MODE=self-check ;;
    --self-test) MODE=self-test ;;
    --detached) DETACHED=1 ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        die 64 "unknown option: $1"
        ;;
    esac
    shift
done

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
bundle_id() { plist "$1" CFBundleIdentifier; }
is_fork_id() { [ "$1" = "$BUNDLE_ID" ] || [ "$1" = "$LEGACY_ID" ]; }
is_fork() { [ -e "$1" ] && is_fork_id "$(bundle_id "$1" || true)"; }
# An ad hoc signature prints its requirement, the cdhash, as a comment.
designated() { codesign -d -r- "$1" 2>&1 | sed -nE 's/^(# )?designated => //p'; }
app_running() { pgrep -f "^$1/Contents/MacOS/" >/dev/null; }
# The Dictation, clipboard-text and file-index helpers run from inside the bundle too.
bundle_running() { pgrep -f "^$1/Contents/" >/dev/null; }

# The fork copy an install replaces: the destination, else one still under the old name.
resolve_installed() {
    INSTALLED=""
    if [ -e "$DEST" ]; then
        INSTALLED="$DEST"
    elif [ "$LEGACY" != "$DEST" ] && is_fork "$LEGACY"; then
        INSTALLED="$LEGACY"
    fi
}

owner() {
    case "$1" in
    com.tinycast.app) echo "upstream's Tinycast, not this fork" ;;
    com.tinycast.app.beta) echo "upstream's Tinycast Beta, not this fork" ;;
    com.tinycast.app.dev) echo "a Debug build, not a fork install" ;;
    *) echo "not this fork" ;;
    esac
}

# A bundle that is not the fork's is never replaced: upstream's has its own grants and settings.
refuse_foreign() {
    die 2 "$1 is ${2:-unreadable}, $(owner "$2"). Point TINYCAST_INSTALL_PATH elsewhere."
}

check_installed() {
    [ -e "$DEST" ] || return 0
    local found
    found="$(bundle_id "$DEST" || true)"
    is_fork_id "$found" || refuse_foreign "$DEST" "$found"
}

# Upstream's Tinycast.app beside the fork is only named. A second fork copy beside an installed
# Redcast.app, which an install.sh from before the rename puts back, is refused: the two would run
# on one bundle id's settings and data, and only one of them would be quit and replaced.
warn_legacy() {
    [ "$LEGACY" != "$DEST" ] && [ -e "$LEGACY" ] || return 0
    if ! is_fork "$LEGACY"; then
        local found
        found="$(bundle_id "$LEGACY" || true)"
        note "! $LEGACY is ${found:-unreadable}, $(owner "$found"): both stay installed."
        return 0
    fi
    [ "$INSTALLED" != "$LEGACY" ] || return 0
    local running=""
    if bundle_running "$LEGACY"; then running=", and it is running"; fi
    if [ "$MODE" = self-check ]; then
        note "! $LEGACY is a second copy of this fork$running: an install would refuse."
        return 0
    fi
    die 2 "$LEGACY is a second copy of this fork beside $DEST$running (an install.sh from" \
        "before the rename installs there). Quit it, move it to the Trash, then rerun."
}

# Every path LaunchServices has registered under the fork's ids, the helper's included.
registered_copies() {
    "$LSREGISTER" -dump 2>/dev/null | awk -v id="$BUNDLE_ID" -v old="$LEGACY_ID" '
        /^-----/ { path = ""; next }
        /^path:/ { sub(/^path:[ ]+/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0; next }
        /^identifier:/ { if (path != "" && ($2 == id || $2 == id ".dictation" || $2 == old || $2 == old ".dictation")) print path }'
}

stale_registrations() {
    registered_copies | while IFS= read -r path; do
        case "$path" in "$1" | "$1"/*) ;; *) printf '%s\n' "$path" ;; esac
    done | sort -u
}

resolve_identity() {
    if [ -n "${TINYCAST_SIGN_IDENTITY:-}" ]; then
        IDENTITY="$TINYCAST_SIGN_IDENTITY"
        return
    fi
    local lines names shas
    lines="$(security find-identity -v -p codesigning 2>/dev/null |
        grep -E '^ *[0-9]+\) [0-9A-F]{40} "Apple Development: ' || true)"
    [ -n "$lines" ] ||
        die 2 "no valid 'Apple Development' signing identity. Set TINYCAST_SIGN_IDENTITY."
    names="$(sed -E 's/^[^"]*"(.*)"$/\1/' <<<"$lines" | sort -u)"
    shas="$(awk '{ print $2 }' <<<"$lines" | sort -u)"
    if [ "$(wc -l <<<"$names")" -ne 1 ] || [ "$(wc -l <<<"$shas")" -ne 1 ]; then
        printf '%s\n' "$lines" >&2
        die 2 "ambiguous signing identity: delete the expired or duplicate certificate in" \
            "Keychain Access, or set TINYCAST_SIGN_IDENTITY to the full name."
    fi
    IDENTITY="$names"
}

resolve_version() {
    local describe
    describe="$(git describe --tags --match 'v[0-9]*' --abbrev=8 --dirty=-dirty 2>/dev/null ||
        echo "v0.0.0-g$(git rev-parse --short=8 HEAD)")"
    VERSION="${describe#v}"
    BUILD="$(git rev-list --count HEAD)"
}

# Walks the parent chain: quitting the app reaps whatever one of its agents or commands started.
started_by_tinycast() {
    local pid=$$ comm app="${INSTALLED:-$DEST}"
    while [ "${pid:-1}" -gt 1 ]; do
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
        [ -n "$pid" ] || return 1
        comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
        case "$comm" in "$app/Contents/"*) return 0 ;; esac
    done
    return 1
}

regrant_steps() {
    cat >&2 <<EOF

The code requirement changes, so macOS asks for every privacy grant once more.
Installed:  $1
New build:  $2

Rerun with --accept-new-identity to go ahead, then reset and re-grant yourself:
  tccutil reset Accessibility $BUNDLE_ID
  tccutil reset ListenEvent $BUNDLE_ID
  tccutil reset ScreenCapture $BUNDLE_ID
  tccutil reset AppleEvents $BUNDLE_ID
  tccutil reset Microphone $BUNDLE_ID.dictation
  tccutil reset SpeechRecognition $BUNDLE_ID.dictation
and re-enable each in System Settings › Privacy & Security.
EOF
}

app_management_hint() {
    case "$1" in
    *"Operation not permitted"*)
        note "macOS App Management is blocking ${TERM_PROGRAM:-this terminal}. Allow it under"
        note "System Settings › Privacy & Security › App Management, or use a terminal that has it."
        ;;
    esac
}

preflight() {
    command -v xcodebuild >/dev/null || die 1 "xcodebuild not found (DEVELOPER_DIR=$DEVELOPER_DIR)."
    if [ project.yml -nt Tinycast.xcodeproj/project.pbxproj ]; then
        note "! project.yml is newer than the project: run \`xcodegen generate\` if it changed."
    fi
    local leftover
    # A run from before the rename left them under the old name.
    for leftover in "$PARENT/.$NAME-staged-"* "$PARENT/.Tinycast-staged-"*; do
        [ -e "$leftover" ] || continue
        if [ "$MODE" = self-check ]; then
            note "would remove the leftover $leftover"
        else
            rm -rf "$leftover"
        fi
    done
    for leftover in "$PARENT/.$NAME-previous-"* "$PARENT/.Tinycast-previous-"*; do
        [ -e "$leftover" ] && note "! $leftover is left from an interrupted swap; check it."
    done
    resolve_installed
    return 0
}

# The build is the fork's, it verifies, and it keeps the installed copy's requirement.
verify_build() {
    [ "$(bundle_id "$BUILT")" = "$BUNDLE_ID" ] ||
        die 1 "$BUILT is $(bundle_id "$BUILT"), expected $BUNDLE_ID."
    ./Scripts/verify-signature.sh "$BUILT" ||
        die 1 "$BUILT does not verify."
    NEW_DR="$(designated "$BUILT")"
    [ -n "$NEW_DR" ] || die 1 "$BUILT has no designated requirement."
    DR_NOTE="new install"
    [ -n "$INSTALLED" ] || return 0
    check_installed
    local old_dr
    old_dr="$(designated "$INSTALLED")"
    MOVES_ID=0
    if [ "$(bundle_id "$INSTALLED" || true)" = "$LEGACY_ID" ]; then
        # The move to Redcast's own id: the app carries settings and data over on its first launch.
        MOVES_ID=1
        DR_NOTE="bundle id $LEGACY_ID → $BUNDLE_ID: privacy grants are asked once more"
    elif [ "$old_dr" = "$NEW_DR" ]; then
        DR_NOTE="unchanged"
    elif [ "$ACCEPT_NEW" -eq 1 ]; then
        DR_NOTE="changed: re-grant Accessibility and the other privacy services once"
    else
        regrant_steps "$old_dr" "$NEW_DR"
        die 2 "refused: the signing identity differs from the installed copy's."
    fi
}

build() {
    resolve_version
    mkdir -p "$WORK"
    say "Building $BUNDLE_ID $VERSION ($BUILD) for $(uname -m), signed by ${IDENTITY}…"
    # Spotlight skips a .noindex folder, so the build output never shows as a second Redcast.app.
    rm -rf "$WORK/DerivedData"
    # PRODUCT_NAME as release.yml passes it; project.yml pins the helpers' names against it.
    if ! xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Release \
        -derivedDataPath "$WORK/DerivedData.noindex" ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
        PRODUCT_NAME="$APP_NAME" DICTATION_EXECUTABLE_NAME="$APP_NAME Dictation" \
        ASSETCATALOG_COMPILER_APPICON_NAME=redcast \
        TINYCAST_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM= \
        OTHER_CODE_SIGN_FLAGS=--timestamp=none \
        MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
        build >"$WORK/build.log" 2>&1; then
        grep -E 'error:' "$WORK/build.log" | sort -u | head -40 >&2 || true
        die 1 "build failed; the full log is $WORK/build.log"
    fi
    local products="$WORK/DerivedData.noindex/Build/Products/Release" product
    BUILT="$products/$APP_NAME.app"
    # Xcode's RegisterWithLaunchServices step would leave tinycast:// pointing in here.
    for product in "$products"/*.app; do
        [ -e "$product" ] && "$LSREGISTER" -u "$product" >/dev/null 2>&1 || true
    done
    verify_build
    ok "Built and verified (requirement: $DR_NOTE)"
}

stage() {
    STAGE="$PARENT/.$NAME-staged-$$"
    rm -rf "$STAGE"
    ditto "$1" "$STAGE" || die 1 "could not stage a copy in $PARENT."
    codesign --verify --deep --strict "$STAGE" || die 1 "the staged copy does not verify."
}

# Before the build: a command's watchdog and Tinycast's quit both signal the group it started.
detach() {
    if [ "$DETACHED" -eq 1 ] || ! started_by_tinycast; then return 0; fi
    mkdir -p "$WORK"
    xcrun python3 -c 'import os,sys
if os.fork(): os._exit(0)
os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
        /bin/bash "$SELF" --detached ${ARGS[@]+"${ARGS[@]}"} </dev/null >"$WORK/install.log" 2>&1 &
    say "Started from the app: the install goes on in a session of its own, $WORK/install.log"
    note "The app quits and comes back once it is installed; a failed build leaves it running."
    exit 0
}

quit_app() {
    local app=$INSTALLED label
    [ -n "$app" ] && bundle_running "$app" || return 0
    label="$(basename "$app" .app)"
    # Asked only while it runs: AppleScript would launch a quit app just to quit it.
    if app_running "$app"; then
        say "Quitting ${label}…"
        osascript -e "tell application id \"$(bundle_id "$app" || echo "$BUNDLE_ID")\" to quit" >/dev/null 2>&1 || true
    fi
    local _
    for _ in $(seq 100); do
        bundle_running "$app" || return 0
        sleep 0.2
    done
    [ "$FORCE_QUIT" -eq 1 ] ||
        die 3 "$label did not quit within 20 s. Quit it from its menu, or rerun with --force-quit."
    note "! forcing $label to quit; an unsaved note draft may be lost."
    pkill -TERM -f "^$app/Contents/" || true
    sleep 2
    pkill -KILL -f "^$app/Contents/" || true
    sleep 0.5
    if bundle_running "$app"; then die 3 "$label is still running after SIGKILL."; fi
    return 0
}

# rename(2) cannot replace a non-empty directory, so two renames, the first undone on failure.
swap() {
    local target=$1 aside="$PARENT/.$NAME-previous-$$" error
    if [ -n "$INSTALLED" ] && ! error="$(mv "$INSTALLED" "$aside" 2>&1)"; then
        printf '%s\n' "$error" >&2
        app_management_hint "$error"
        die 4 "could not move the installed copy aside; nothing changed."
    fi
    if ! error="$(mv "$STAGE" "$target" 2>&1)"; then
        printf '%s\n' "$error" >&2
        [ -e "$aside" ] && mv "$aside" "$INSTALLED"
        app_management_hint "$error"
        die 4 "swap failed; the previous copy is back in place."
    fi
    STAGE=""
    # The slot changes only when this swap replaced a copy, and a copy it cannot keep stays put.
    if [ -e "$aside" ]; then
        mkdir -p "$WORK"
        rm -rf "$PREVIOUS" "$PREVIOUS_ORIGIN"
        if error="$(mv "$aside" "$PREVIOUS" 2>&1)"; then
            printf '%s\n' "$INSTALLED" >"$PREVIOUS_ORIGIN"
        else
            note "! could not keep the replaced copy for --rollback: $error"
            note "! it is $aside; remove it once $target works."
        fi
    fi
    ok "Swapped into $target"
}

register() {
    local live=$1 path
    "$LSREGISTER" -f "$live" || true
    # The copy a migration moved away; LaunchServices would keep offering its old path.
    if [ -n "$INSTALLED" ] && [ "$INSTALLED" != "$live" ]; then
        "$LSREGISTER" -u "$INSTALLED" >/dev/null 2>&1 || true
        note "unregistered $INSTALLED"
    fi
    while IFS= read -r path; do
        [ -n "$path" ] && [ "$path" != "$INSTALLED" ] || continue
        "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
        note "unregistered $path"
    done < <(stale_registrations "$live")
}

relaunch() {
    local live=$1 label
    label="$(basename "$live" .app)"
    if [ "$LAUNCH" -eq 1 ]; then
        open "$live"
        local _
        for _ in $(seq 50); do
            app_running "$live" && break
            sleep 0.2
        done
        app_running "$live" || note "! $label did not start within 10 s; open it by hand."
    fi
    local authority
    authority="$(codesign -dvv "$live" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    ok "Installed $label $(plist "$live" CFBundleShortVersionString || echo "?")" \
        "($(plist "$live" CFBundleVersion || echo "?"))"
    note "identity:    ${authority:-ad hoc}"
    note "requirement: $DR_NOTE"
    note "path:        $live ($(du -sh "$live" | awk '{ print $1 }'))"
    if [ "${MOVES_ID:-0}" -eq 1 ]; then
        note "bundle id:   now $BUNDLE_ID. On its first launch $label moves its settings, Application"
        note "             Support and settings.json from $LEGACY_ID (the old paths become links), and"
        note "             each Keychain key the first time it is used (macOS may ask once to allow it)."
        note "             Re-grant Accessibility, Input Monitoring, Screen Recording, Automation and the"
        note "             Dictation helper's Microphone in System Settings › Privacy & Security, switch"
        note "             Launch at login off and on, and update Agent Sessions' live status if it is on."
    fi
    if [ -n "$INSTALLED" ] && [ "$INSTALLED" != "$live" ]; then
        note "renamed:     $(basename "$INSTALLED") is in the rollback slot; --rollback restores it"
        note "Privacy grants follow the bundle id and code requirement, so they carry over. The"
        note "login item may still name the old path: if $label does not open at login, switch"
        note "Settings › General › Launch at login off and on (see System Settings › Login Items)."
    fi
    note "If a Screen Awareness capture says Accessibility is refused while other apps work,"
    note "quit and reopen the app you captured."
}

# A slot kept by a migration returns under its old name; one from before keeps today's place.
rollback_target() {
    TARGET=""
    [ ! -f "$PREVIOUS_ORIGIN" ] || TARGET="$(cat "$PREVIOUS_ORIGIN")"
    case "$TARGET" in
    "") TARGET="${INSTALLED:-$DEST}" ;;
    "$DEST" | "$LEGACY") ;;
    *) die 2 "the rollback copy was installed at $TARGET, not $DEST; set TINYCAST_INSTALL_PATH." ;;
    esac
    if [ -e "$TARGET" ] && [ "$TARGET" != "$INSTALLED" ]; then
        die 2 "$TARGET is in the way of the rollback ($(bundle_id "$TARGET" || echo unreadable))."
    fi
}

finish() {
    quit_app
    swap "$1"
    register "$1"
    relaunch "$1"
}

self_check() {
    preflight
    resolve_identity
    resolve_version
    ok "repository:  $ROOT"
    note "xcodebuild:  $(command -v xcodebuild) ($DEVELOPER_DIR)"
    note "identity:    $IDENTITY"
    note "version:     $VERSION ($BUILD)"
    note "bundle id:   $BUNDLE_ID"
    note "install to:  $DEST ($APP_NAME.app, helper $APP_NAME Dictation)"
    if [ -n "$INSTALLED" ]; then
        note "installed:   $INSTALLED, $(bundle_id "$INSTALLED" || echo unreadable)" \
            "$(plist "$INSTALLED" CFBundleShortVersionString || true)"
        note "requirement: $(designated "$INSTALLED")"
        check_installed
    else
        note "installed:   nothing yet"
    fi
    if [ "$INSTALLED" = "$LEGACY" ] && [ "$LEGACY" != "$DEST" ]; then
        note "migrate:     $LEGACY → $DEST; the old copy goes to the rollback slot and"
        note "             LaunchServices forgets it. Grants carry over; Launch at login may need"
        note "             switching off and on."
    fi
    warn_legacy
    if [ -e "$PREVIOUS" ]; then
        note "rollback to: $PREVIOUS, at" \
            "$(cat "$PREVIOUS_ORIGIN" 2>/dev/null || echo "${INSTALLED:-$DEST}")"
    else
        note "rollback to: none"
    fi
    if started_by_tinycast; then note "started by:  the installed app (an install would detach)"; fi
    local path count=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        note "would unregister $path"
        count=$((count + 1))
    done < <(stale_registrations "$DEST")
    [ "$count" -gt 0 ] || note "LaunchServices: only $DEST is registered"
    ok "self-check passed; nothing was built, moved or registered"
}

# A fake build verify-signature.sh accepts; quit, open and lsregister never reach the system.
stub_tools() {
    local bin=$1
    xcrun clang -O1 -o "$bin/launcher" -x c - <<'EOF'
#include <errno.h>
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;
int main(int argc, char **argv) {
    pid_t pid;
    int status = 0;
    if (argc < 2 || posix_spawn(&pid, argv[1], NULL, NULL, argv + 1, environ) != 0) return 127;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
EOF
    {
        printf '#!/bin/bash\nset -eu\nLAUNCHER=%q PGID=%q\n' "$bin/launcher" "$TEST_ROOT/build.pgid"
        cat <<'EOF'
data="" id="" version="" name=Tinycast dictation="Tinycast Dictation"
while [ $# -gt 0 ]; do
    case "$1" in
    -derivedDataPath) data="$2" && shift ;;
    TINYCAST_BUNDLE_IDENTIFIER=*) id="${1#*=}" ;;
    MARKETING_VERSION=*) version="${1#*=}" ;;
    PRODUCT_NAME=*) name="${1#*=}" ;;
    DICTATION_EXECUTABLE_NAME=*) dictation="${1#*=}" ;;
    esac
    shift
done
ps -o pgid= -p $$ | tr -d ' ' >>"$PGID"
info() {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>\n'
    printf '<key>%s</key><string>%s</string>\n' CFBundleIdentifier "$1" \
        CFBundleExecutable "$2" CFBundlePackageType APPL CFBundleShortVersionString "$version"
    printf '</dict></plist>\n'
}
app="${data:?}/Build/Products/Release/$name.app"
helper="$app/Contents/Helpers/$dictation.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$helper/Contents/MacOS"
cp "$LAUNCHER" "$app/Contents/MacOS/$name"
cp "$LAUNCHER" "$app/Contents/Helpers/ClipboardTextHelper"
cp "$LAUNCHER" "$helper/Contents/MacOS/$dictation"
info "$id" "$name" >"$app/Contents/Info.plist"
info "$id.dictation" "$dictation" >"$helper/Contents/Info.plist"
for code in "$app/Contents/Helpers/ClipboardTextHelper" "$helper" "$app"; do
    codesign -s - -o runtime -f "$code" 2>/dev/null
done
EOF
    } >"$bin/xcodebuild"
    local tool
    for tool in osascript open lsregister; do
        printf '#!/bin/sh\necho "$*" >>%q\n' "$TEST_ROOT/$tool.log" >"$bin/$tool"
    done
    chmod +x "$bin/"*
}

check() {
    local message=$1
    shift
    if "$@"; then
        PASSES=$((PASSES + 1))
    else
        FAILURES=$((FAILURES + 1))
        printf 'FAIL: %s\n' "$message"
        sed 's/^/    /' "$TEST_ROOT/out.log" "$TEST_ROOT/repo/build/fork/install.log" 2>/dev/null ||
            true
    fi
}

version() { plist "$1" CFBundleShortVersionString 2>/dev/null || echo none; }

# Every build the stub ran wrote its process group; none may be the caller's.
built_outside() { [ -s "$TEST_ROOT/build.pgid" ] && ! grep -qx "$1" "$TEST_ROOT/build.pgid"; }

# An installed copy named as its path says, with the helpers that name implies.
fake_app() {
    local name
    name="$(basename "$1" .app)"
    "$TEST_ROOT/bin/xcodebuild" -derivedDataPath "$TEST_ROOT/seed" PRODUCT_NAME="$name" \
        DICTATION_EXECUTABLE_NAME="$name Dictation" TINYCAST_BUNDLE_IDENTIFIER="$2" \
        MARKETING_VERSION="$3" build
    mkdir -p "$(dirname "$1")"
    ditto "$TEST_ROOT/seed/Build/Products/Release/$name.app" "$1"
    rm -f "$TEST_ROOT/build.pgid"
}

# Starts the copied script the way an agent's command does: as a child of the installed app.
from_app() {
    local status=0
    "$1/Contents/MacOS/$(plist "$1" CFBundleExecutable)" /bin/bash \
        "$TEST_ROOT/repo/Scripts/fork/install.sh" "${@:2}" >"$TEST_ROOT/out.log" 2>&1 || status=$?
    printf '%s' "$status"
}

# Runs the copied script from no app at all, its output where `check` prints it from.
install_status() {
    local status=0
    "$TEST_ROOT/repo/Scripts/fork/install.sh" "$@" >"$TEST_ROOT/out.log" 2>&1 || status=$?
    printf '%s' "$status"
}

unregistered() { grep -qxF -- "-u $1" "$TEST_ROOT/lsregister.log" 2>/dev/null; }

# Done once the log has its last word and the detached script has exited.
finished() {
    local _
    for _ in $(seq 150); do
        if grep -q '^✓ Installed\|^✗' "$1" 2>/dev/null &&
            ! pgrep -f "$TEST_ROOT/repo/Scripts/fork/install.sh --detached" >/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

self_test() {
    TEST_ROOT="${TMPDIR:-/tmp}"
    TEST_ROOT="${TEST_ROOT%/}/tinycast-install-selftest-$(uuidgen)"
    local repo="$TEST_ROOT/repo" app="$TEST_ROOT/Applications/$APP_NAME.app" status own
    local log="$TEST_ROOT/repo/build/fork/install.log" id=com.tinycast.app.fork.selftest
    local slot="$TEST_ROOT/repo/build/fork/Tinycast.previous" old new upstream
    mkdir -p "$repo/Scripts/fork" "$TEST_ROOT/bin"
    [ -n "${TINYCAST_INSTALL_KEEP:-}" ] || trap 'rm -rf "$TEST_ROOT"' EXIT
    cp "$SELF" "$repo/Scripts/fork/install.sh"
    cp "$ROOT/Scripts/verify-signature.sh" "$repo/Scripts/"
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git -C "$repo" init -q && git -C "$repo" add -A
    git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit -q -m Base
    git -C "$repo" tag v2.0.0
    stub_tools "$TEST_ROOT/bin"
    export PATH="$TEST_ROOT/bin:$PATH" TINYCAST_LSREGISTER="$TEST_ROOT/bin/lsregister" \
        TINYCAST_SIGN_IDENTITY=- TINYCAST_FORK_BUNDLE_ID="$id" TINYCAST_INSTALL_PATH="$app"
    PASSES=0 FAILURES=0
    own="$(ps -o pgid= -p $$ | tr -d ' ')"

    fake_app "$app" "$id" 1.0
    status="$(install_status --no-launch)"
    check "an ad hoc build, whose requirement always changes, is refused (exit $status)" \
        [ "$status" = 2 ]
    check "with both requirements printed" [ "$(grep -c 'cdhash H' "$TEST_ROOT/out.log")" = 2 ]
    check "and the installed copy left alone" [ "$(version "$app")" = 1.0 ]
    rm -f "$TEST_ROOT/build.pgid"

    status="$(from_app "$app" --no-launch --accept-new-identity)"
    check "started from the app, it returns at once (exit $status)" [ "$status" = 0 ]
    check "saying where the install goes on" grep -q "session of its own" "$TEST_ROOT/out.log"
    check "the detached install finishes" finished "$log"
    check "having built outside the caller's process group" built_outside "$own"
    check "the new build is installed" [ "$(version "$app")" = 2.0.0 ]
    check "named $APP_NAME, its Dictation helper too" \
        [ "$(plist "$app" CFBundleExecutable)" = "$APP_NAME" -a \
        -x "$app/Contents/Helpers/$APP_NAME Dictation.app/Contents/MacOS/$APP_NAME Dictation" ]
    check "and the old one kept for --rollback" [ "$(version "$slot")" = 1.0 ]
    check "--no-launch opens nothing" [ ! -e "$TEST_ROOT/open.log" ]

    status="$(install_status --rollback --no-launch)"
    check "started elsewhere, --rollback runs in place (exit $status)" [ "$status" = 0 ]
    check "and puts the old build back" [ "$(version "$app")" = 1.0 ]

    old="$TEST_ROOT/Migrate/Tinycast.app" new="$TEST_ROOT/Migrate/$APP_NAME.app"
    export TINYCAST_INSTALL_PATH="$new"
    rm -rf "$slot" "$log"
    fake_app "$old" "$id" 1.5
    status="$(install_status --self-check)"
    check "--self-check plans the migration (exit $status)" \
        grep -q "migrate: .*$old → $new" "$TEST_ROOT/out.log"
    status="$(install_status --no-launch)"
    check "a fork copy under the old name is checked against the new build (exit $status)" \
        [ "$status" = 2 -a "$(version "$old")" = 1.5 -a ! -e "$new" ]
    rm -f "$TEST_ROOT/build.pgid"
    status="$(from_app "$old" --no-launch --accept-new-identity)"
    check "started from the old copy, it returns at once (exit $status)" [ "$status" = 0 ]
    check "having detached from it" grep -q "session of its own" "$TEST_ROOT/out.log"
    check "the migration finishes" finished "$log"
    check "installing the new name" [ "$(version "$new")" = 2.0.0 ]
    check "with the old copy in the rollback slot" [ ! -e "$old" -a "$(version "$slot")" = 1.5 ]
    check "and unregistered" unregistered "$old"
    check "and the summary names the grants and Open at login" \
        grep -q "Privacy grants follow the bundle id" "$log"
    status="$(install_status --rollback --no-launch)"
    check "--rollback undoes the migration (exit $status)" \
        [ "$status" = 0 -a "$(version "$old")" = 1.5 -a ! -e "$new" ]
    check "keeping the new copy for a second --rollback" [ "$(version "$slot")" = 2.0.0 ]
    check "and unregistering it" unregistered "$new"
    status="$(install_status --rollback --no-launch)"
    check "which migrates again (exit $status)" \
        [ "$status" = 0 -a "$(version "$new")" = 2.0.0 -a ! -e "$old" ]

    upstream="$TEST_ROOT/Shared/Tinycast.app"
    export TINYCAST_INSTALL_PATH="$TEST_ROOT/Shared/$APP_NAME.app"
    fake_app "$upstream" com.tinycast.app 9.0
    status="$(install_status --no-launch)"
    check "next to upstream's Tinycast.app the fork installs (exit $status)" \
        [ "$status" = 0 -a "$(version "$TINYCAST_INSTALL_PATH")" = 2.0.0 ]
    check "saying both stay" grep -q "upstream's Tinycast, not this fork: both stay" \
        "$TEST_ROOT/out.log"
    check "and leaves upstream's in place" [ "$(version "$upstream")" = 9.0 ]
    check "and registered" sh -c '! grep -qxF -- "-u $1" "$2"' - "$upstream" \
        "$TEST_ROOT/lsregister.log"
    check "a fresh install keeps the last rollback copy" [ "$(version "$slot")" = 1.5 ]

    old="$TEST_ROOT/Twice/Tinycast.app" new="$TEST_ROOT/Twice/$APP_NAME.app"
    export TINYCAST_INSTALL_PATH="$new"
    fake_app "$new" "$id" 2.0.0
    fake_app "$old" "$id" 1.9
    status="$(install_status --self-check)"
    check "--self-check names a second fork copy beside $APP_NAME.app (exit $status)" \
        grep -q "$old is a second copy of this fork: an install would refuse" "$TEST_ROOT/out.log"
    status="$(install_status --no-launch --accept-new-identity)"
    check "which an install refuses (exit $status)" \
        [ "$status" = 2 -a "$(version "$old")" = 1.9 -a "$(version "$new")" = 2.0.0 ]
    check "before it builds, saying why" test ! -e "$TEST_ROOT/build.pgid" -a \
        "$(grep -c "second copy of this fork beside $new" "$TEST_ROOT/out.log")" = 1
    status="$(install_status --rollback --no-launch)"
    check "and so does --rollback (exit $status)" \
        [ "$status" = 2 -a "$(version "$new")" = 2.0.0 -a "$(version "$slot")" = 1.5 ]
    check "for the same reason" grep -q "second copy of this fork" "$TEST_ROOT/out.log"

    rm -f "$log"
    fake_app "$TEST_ROOT/Other/$APP_NAME.app" com.example.other 9.0
    export TINYCAST_INSTALL_PATH="$TEST_ROOT/Other/$APP_NAME.app"
    status="$(from_app "$TINYCAST_INSTALL_PATH" --no-launch)"
    check "a foreign app is refused to the caller (exit $status)" [ "$status" = 2 ]
    check "before anything detaches or builds" test ! -e "$log" -a ! -e "$TEST_ROOT/build.pgid"

    printf '%d passed, %d failed\n' "$PASSES" "$FAILURES"
    [ "$FAILURES" -eq 0 ] || exit 1
    ok "install self-test passed"
}

# A failing command in an EXIT trap would replace the exit code the script chose.
cleanup() { if [ -n "$STAGE" ] && [ -e "$STAGE" ]; then rm -rf "$STAGE" 2>/dev/null || true; fi; }

case "$MODE" in
self-check)
    self_check
    ;;
self-test)
    self_test
    ;;
install)
    preflight
    # Refusals that need no build answer the caller before anything detaches.
    resolve_identity
    check_installed
    warn_legacy
    detach
    trap cleanup EXIT
    build
    stage "$BUILT"
    finish "$DEST"
    ;;
rollback)
    preflight
    [ -e "$PREVIOUS" ] || die 1 "nothing to roll back to: $PREVIOUS does not exist."
    [ "$(bundle_id "$PREVIOUS")" = "$BUNDLE_ID" ] || die 2 "$PREVIOUS is not a $BUNDLE_ID build."
    check_installed
    warn_legacy
    rollback_target
    detach
    DR_NOTE="rolled back"
    trap cleanup EXIT
    # Staged on the destination volume, so the swap stays two renames.
    stage "$PREVIOUS"
    finish "$TARGET"
    ;;
esac
