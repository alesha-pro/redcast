#!/bin/bash
# Measures AI Chat's window over a fixture history, footprint and malloc per step; not in run-tests.
# Usage: Scripts/fork/chat-memory.sh [report.tsv] [source tree] [cycles]
#   CHAT_MEMORY_ONSCREEN=1 shows the window (otherwise it is moved off every screen);
#   CHAT_MEMORY_SCROLL=1 times steady scrolls through two long chats instead of the memory steps;
#   CHAT_MEMORY_CENSUS=1 adds a heap count of the watched classes after every step of the last cycle;
#   CHAT_MEMORY_GRAPH=<step,…> saves a memory graph at those steps of the last cycle;
#   CHAT_MEMORY_DETAIL=1 dumps footprint and heap per step of the first cycle;
#   CHAT_MEMORY_EARLY=<s> also dumps them, with the layers, that long after each switch;
#   CHAT_MEMORY_SHOTS=<dir> saves the window's layers after each switch;
#   CHAT_MEMORY_PANES=1 measures Settings and the Extension Store instead of the chat window;
#   CHAT_MEMORY_REUSE=1 skips the rebuild; CHAT_MEMORY_BUILD_ONLY=1 stops after it.
# See docs/features/chat-workspace.md#memory and docs/testing.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="$ROOT/Tests/chat-memory-harness.swift"
REPORT=$(cd "$(dirname "${1:-chat-memory.tsv}")" && pwd)/$(basename "${1:-chat-memory.tsv}")
SRC=$(cd "${2:-$ROOT}" && pwd)
CYCLES=${3:-3}
ID=com.tinycast.chat-memory
WORK="${TMPDIR:-/tmp}/tinycast-chat-memory/$(basename "$SRC")"
BUNDLE="$WORK/ChatMemory.app"
SUPPORT="$HOME/Library/Application Support/$ID"
BIN="$BUNDLE/Contents/MacOS/chat-memory"
GUARD="$WORK/no-keychain.dylib"
# One place for every tree's run, so the replies name the same paths and wrap alike.
FILES="${TMPDIR:-/tmp}/tinycast-chat-memory/files"

# The harness's own channel: its defaults and Application Support are emptied before and after.
reset() {
    defaults delete "$ID" >/dev/null 2>&1 || true
    rm -rf "$SUPPORT" "$HOME/Library/Caches/$ID" "$FILES"
}
trap reset EXIT

# Every SecItem call is refused in the process, so no run ever reads or writes a Keychain item.
build_guard() {
    mkdir -p "$WORK"
    clang -dynamiclib -O2 -framework Security -framework CoreFoundation -o "$GUARD" -x c - <<'C'
#include <Security/Security.h>
#include <stdio.h>
#define INTERPOSE(replacement, replacee) \
    __attribute__((used)) static const struct { const void *with, *what; } interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&replacee };
static void refused(const char *call) { fprintf(stderr, "chat-memory: refused %s\n", call); }
static OSStatus copyMatching(CFDictionaryRef query, CFTypeRef *result) {
    refused("SecItemCopyMatching");
    if (result) *result = NULL;
    return errSecItemNotFound;
}
static OSStatus add(CFDictionaryRef attributes, CFTypeRef *result) {
    refused("SecItemAdd");
    if (result) *result = NULL;
    return errSecNotAvailable;
}
static OSStatus update(CFDictionaryRef query, CFDictionaryRef attributes) {
    refused("SecItemUpdate");
    return errSecItemNotFound;
}
static OSStatus delete(CFDictionaryRef query) {
    refused("SecItemDelete");
    return errSecItemNotFound;
}
INTERPOSE(copyMatching, SecItemCopyMatching)
INTERPOSE(add, SecItemAdd)
INTERPOSE(update, SecItemUpdate)
INTERPOSE(delete, SecItemDelete)
__attribute__((constructor)) static void loaded(void) { fputs("chat-memory: Keychain guarded\n", stderr); }
C
}

build() {
    rm -rf "$BUNDLE"
    mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
    xcrun actool --compile "$BUNDLE/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
        --accent-color AccentColor --output-partial-info-plist "$WORK/assets.plist" \
        "$SRC/Tinycast/Assets.xcassets" >/dev/null
    xcrun xcstringstool compile "$SRC/Tinycast/Resources/Localizable.xcstrings" \
        --output-directory "$BUNDLE/Contents/Resources" >/dev/null
    cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$ID</string>
<key>CFBundleExecutable</key><string>chat-memory</string>
<key>CFBundleName</key><string>Chat Memory</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

    # The app's own sources, as project.yml builds them, minus its @main and the helpers' files.
    SOURCES=()
    while IFS= read -r file; do SOURCES+=("$file"); done < <(
        find "$SRC/Tinycast" -name '*.swift' \
            ! -path '*/App/TinycastApp.swift' ! -path '*/Features/Clipboard/Service/ClipboardTextExtractor.swift' \
            ! -path '*/Features/Clipboard/Service/ClipboardTextHelper.swift' ! -path '*/Features/DocumentText/Helper/*' \
            ! -path '*/Features/Dictation/Helper/*' ! -path '*/Features/FileSearch/Helper/*' | sort)
    FLAGS=()
    [ -d "$SRC/Tinycast/Features/ChatWorkspace" ] || FLAGS+=(-D CHAT_MEMORY_LEGACY)
    echo "compiling ${#SOURCES[@]} files from $SRC (-O)…"
    swiftc -swift-version 6 -target arm64-apple-macos26.0 -O -wmo -num-threads 8 ${FLAGS[@]+"${FLAGS[@]}"} "${SOURCES[@]}" "$HARNESS" \
        -o "$BIN"
}
# CHAT_MEMORY_REUSE=1 measures the binary the last run built, for repeated runs of one tree.
[ -n "${CHAT_MEMORY_REUSE:-}" ] && [ -x "$BIN" ] || build
[ -f "$GUARD" ] || build_guard
[ -z "${CHAT_MEMORY_BUILD_ONLY:-}" ] || exit 0
reset
run() { DYLD_INSERT_LIBRARIES="$GUARD" "$BIN" "$@" -AppleLanguages "(en)"; }
run fixtures "$FILES"
if [ -n "${CHAT_MEMORY_PANES:-}" ]; then
    run panes "$REPORT" "$CYCLES"
elif [ -n "${CHAT_MEMORY_SCROLL:-}" ]; then
    run scroll "$REPORT" "$CYCLES"
else
    run measure "$REPORT" "$CYCLES"
fi
echo "report: $REPORT"
