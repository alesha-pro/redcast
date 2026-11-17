#!/bin/bash
# The test suite: each harness compiles the shipped sources it guards. See docs/testing.md.

set -uo pipefail

# Absolute: the workers re-enter this script after the cd, where a relative $0 would not resolve.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.." || exit 1

BIN="${TMPDIR:-/tmp}/redcast-harness"
mkdir -p "$BIN"

# `--exec` is the worker half: xargs re-enters here once per queued harness.
if [ "${1:-}" = "--exec" ]; then
    shift
    name=$1 opt=$2
    shift 2
    : > "$BIN/$name.running"
    trap 'rm -f "$BIN/$name.running" "$BIN/$name.time"' EXIT
    fail() {
        printf '\033[31mFAIL\033[0m  %-25s %s\n' "$name" "$1"
        : > "$BIN/$name.failed"
        exit 0
    }
    TIMEFORMAT=%1R
    if ! compiled=$( { time swiftc -swift-version 6 "$opt" "$@" "Tests/$name.swift" -o "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2>&1 ); then
        fail "did not compile"
    fi
    { time "$BIN/$name" > "$BIN/$name.log" 2>&1; } 2> "$BIN/$name.time" &
    pid=$!
    # macOS ships no `timeout`, so the worker polls; a wedged harness must fail, not stall.
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((REDCAST_TEST_TIMEOUT * 5)) ]; then
            { pkill -KILL -P "$pid"; kill -KILL "$pid"; wait "$pid"; } 2>/dev/null
            printf '\n[run-tests] killed after %ss without finishing\n' "$REDCAST_TEST_TIMEOUT" >> "$BIN/$name.log"
            fail "timed out after ${REDCAST_TEST_TIMEOUT}s"
        fi
        ticks=$((ticks + 1))
        sleep 0.2
    done
    wait "$pid"
    status=$?
    took=$(< "$BIN/$name.time")
    if [ "$status" -gt 128 ]; then fail "crashed (signal $((status - 128))) after ${took}s"; fi
    if [ "$status" -ne 0 ]; then fail "assertion failed after ${took}s"; fi
    printf '\033[32mok\033[0m    %-25s %5ss  \033[2m(compile %ss)\033[0m\n' "$name" "$took" "$compiled"
    exit 0
fi

QUEUE="$BIN/queue"
EXCLUSIVE_QUEUE="$BIN/exclusive-queue"
: > "$QUEUE"
: > "$EXCLUSIVE_QUEUE"
rm -f "$BIN"/*.failed "$BIN"/*.running

failed=()
ran=0
only="${1:-}"

# `--index` feeds harness compile commands to .compile, as xcodebuild never compiles Tests/.
emit_db=0
DB="${TMPDIR:-/tmp}/redcast-compile-db.json"
if [ "$only" = "--index" ]; then
    emit_db=1
    only=""
    printf '[' > "$DB"
fi

# `slow` dispatches in the first wave; `index` only claims editor flags for a hand-run harness.
run() {
    local opt=-Onone pri=1 index_only=0 queue="$QUEUE"
    while :; do
        case "$1" in
            slow)  pri=0; shift;;
            exclusive) queue="$EXCLUSIVE_QUEUE"; shift;;
            -O)    opt=-O; shift;;
            index) index_only=1; shift;;
            *)     break;;
        esac
    done
    local name=$1
    shift
    if [ -n "$only" ] && [ "$name" != "$only" ]; then return 0; fi
    if [ "$index_only" -eq 1 ] && [ "$emit_db" -eq 0 ]; then return 0; fi
    ran=$((ran + 1))

    # Absolute paths: sourcekit-lsp ignores `directory` for relative arguments and indexes nothing.
    if [ "$emit_db" -eq 1 ]; then
        local sources=()
        for source in "$@" "Tests/$name.swift"; do sources+=("$PWD/$source"); done
        [ "$ran" -gt 1 ] && printf ',' >> "$DB"
        printf '{"directory":"%s","command":"swiftc -swift-version 6 -sdk %s' \
            "$PWD" "$(xcrun --show-sdk-path --sdk macosx)" >> "$DB"
        printf ' %s' "${sources[@]}" >> "$DB"
        # Only `Tests/` files: `.compile` is last-wins, so a shipped source keeps the app's command.
        local claimed=""
        for source in "${sources[@]}"; do
            case "$source" in *"/Tests/"*) claimed="$claimed${claimed:+,}\"$source\"";; esac
        done
        printf '","files":[%s]}' "$claimed" >> "$DB"
        return 0
    fi

    # xargs splits the queue on whitespace, so no harness source path may contain a space.
    printf '%s %s %s %s\n' "$pri" "$name" "$opt" "$*" >> "$queue"
}

L=Redcast/Features/Launcher/Model
run slow -O fuzz-test      $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/LauncherMatch.swift $L/EntryNaming.swift $L/LauncherOrder.swift \
                           $L/LauncherRankingStore.swift $L/LauncherSuggestions.swift
FS=Redcast/Features/FileSearch
FILE_INDEX="$FS/Service/FileIndex.swift $FS/Service/FileIndexSnapshot.swift $FS/Service/FileIndexCrawler.swift"
run file-search-test       $FS/Model/*.swift
run file-index-test        $FS/Model/*.swift $FILE_INDEX
run file-search-session-test $FS/Model/*.swift $FS/Service/FileSearchSession.swift $FILE_INDEX
run menu-search-test       $L/SearchRelevance.swift \
                           Redcast/Features/MenuSearch/Model/*.swift \
                           Redcast/Features/MenuSearch/Service/*.swift
run window-switch-test     $L/SearchRelevance.swift \
                           Redcast/Features/WindowSwitcher/Model/*.swift
run index file-search-performance $FS/Model/*.swift $FILE_INDEX
run ranking-test           $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/LauncherMatch.swift $L/LauncherRankingStore.swift
run scopes-test            $L/SearchScopes.swift
run app-name-test          Redcast/Platform/AppDisplayName.swift \
                           Redcast/Platform/BundleLocalization.swift \
                           $L/SearchRelevance.swift
run favorites-test         $L/FavoriteSlots.swift
run app-installation-test  $L/SearchRelevance.swift $L/ScriptRomanization.swift \
                           $L/LauncherMatch.swift $L/EntryNaming.swift $L/LauncherOrder.swift \
                           $L/LauncherRankingStore.swift $L/LauncherSuggestions.swift $L/SearchScopes.swift \
                           Redcast/Features/Launcher/Service/AppIndex.swift \
                           Redcast/Features/Launcher/Service/AppLauncher.swift \
                           Redcast/Features/Launcher/Service/RunningAppsMonitor.swift \
                           Redcast/Features/Launcher/Service/FavoritesStore.swift \
                           Redcast/Features/Launcher/Service/AliasStore.swift \
                           Redcast/Features/Launcher/Service/VisibilityStore.swift \
                           Redcast/Features/Launcher/Service/BundleNameCache.swift \
                           Redcast/Platform/AppDisplayName.swift Redcast/Platform/BundleLocalization.swift \
                           Redcast/Platform/SystemLanguages.swift \
                           Redcast/Platform/Images/FileIconStamp.swift Redcast/Platform/Memo.swift \
                           Redcast/Platform/Signposts.swift Redcast/Platform/NotificationToken.swift \
                           Redcast/Platform/LocalizedResource.swift
run launcher-file-test     $L/LauncherFileFormat.swift \
                           Redcast/Features/Settings/Model/SettingsFileJSON.swift
run launcher-settings-file-test \
                           $L/LauncherFileFormat.swift $L/CommandID.swift $L/CommandCatalog.swift \
                           Redcast/Features/Launcher/Service/LauncherSettingsFile.swift \
                           Redcast/Features/Launcher/Service/AliasStore.swift \
                           Redcast/Features/Launcher/Service/VisibilityStore.swift \
                           Redcast/Features/Settings/SettingsTab.swift \
                           Redcast/Features/Settings/Model/*.swift \
                           Redcast/Features/HotKeys/Service/HotKeySettingsFile.swift \
                           Redcast/Features/HotKeys/Service/KeyShortcut.swift \
                           Redcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Redcast/Features/HotKeys/Model/HotKeyBinding.swift \
                           Redcast/Features/HotKeys/Model/HotKeySpelling.swift \
                           Redcast/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Redcast/Features/HotKeys/Model/ModifierKey.swift \
                           Redcast/Features/HotKeys/Model/HyperKey.swift \
                           Redcast/Features/HotKeys/Model/HIDKeyMapping.swift \
                           Redcast/Platform/ASCIIKeyboardLayout.swift \
                           Redcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Redcast/Features/Quicklinks/Model/Quicklink.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Redcast/Features/SystemActions/Model/SystemAction.swift \
                           Redcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Redcast/Features/Snippets/Model/Snippet.swift \
                           Redcast/Platform/LocalizedResource.swift
run apple-shortcut-test    Redcast/Features/AppleShortcuts/Model/*.swift
run calc-test              Redcast/Features/Calculator/Model/*.swift
run index calc-performance Redcast/Features/Calculator/Model/*.swift
run calendar-test          Redcast/Features/Calendar/Model/*.swift \
                           Redcast/Features/Calendar/UI/EventEditorSession.swift
run clipboard-test         Redcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Redcast/Platform/Images/ImageDerivative.swift \
                           Redcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Redcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Redcast/Features/Clipboard/Model/ColorValue.swift \
                           Redcast/Features/Clipboard/Model/ColorFormat.swift \
                           Redcast/Features/Clipboard/Model/ColorSpaces.swift
run clipboard-coordinator-test Redcast/Features/Clipboard/UI/ClipboardCoordinator.swift \
                           Redcast/Features/Clipboard/Model/*.swift \
                           Redcast/Platform/Images/ImageDerivative.swift \
                           Redcast/Palette/PaletteState.swift Redcast/Palette/PaletteMode.swift \
                           Redcast/Palette/HoverArming.swift \
                           Redcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Redcast/Features/FileSearch/Model/FileSearchFilter.swift \
                           Redcast/Features/Quicklinks/Model/Quicklink.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Redcast/Features/CustomCommands/Model/CustomCommand.swift
run clipboard-thumbnail-test Redcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Redcast/Platform/Images/ImageDerivative.swift \
                           Redcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Redcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Redcast/Features/Clipboard/Model/ColorValue.swift \
                           Redcast/Features/Clipboard/Model/ColorFormat.swift \
                           Redcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Redcast/Platform/ProcessExit.swift \
                           Redcast/Platform/Images/ImageThumbnail.swift \
                           Redcast/Platform/Images/ThumbnailCache.swift
# `Q` is the URL detector a drag payload builds its link with, rather than a second one.
Q=Redcast/Features/Quicklinks/Model/QuicklinkDestination.swift
run clipboard-search-test  Redcast/Features/Clipboard/Model/*.swift Redcast/Platform/Images/ImageDerivative.swift $Q
run paste-sequence-test    Redcast/Features/Clipboard/Model/*.swift Redcast/Platform/Images/ImageDerivative.swift $Q
run clipboard-text-test    Redcast/Features/Clipboard/Model/*.swift Redcast/Platform/Images/ImageDerivative.swift $Q \
                           Redcast/Features/Clipboard/Service/ClipboardTextExtractor.swift \
                           Redcast/Features/Clipboard/Service/ClipboardTextIndexer.swift \
                           Redcast/Features/Clipboard/Service/ClipboardTextWorker.swift \
                           Redcast/Platform/ProcessExit.swift
# Fork: documents read for agents; the harness is its own helper, as the app's ClipboardTextHelper is.
run document-text-test     Redcast/Features/DocumentText/Model/*.swift \
                           Redcast/Features/DocumentText/Service/*.swift \
                           Redcast/Features/DocumentText/Helper/*.swift \
                           Redcast/Features/Clipboard/Service/ClipboardTextExtractor.swift \
                           Redcast/Platform/ProcessExit.swift
run pasteboard-test        Redcast/Platform/PasteboardFiles.swift \
                           Redcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Redcast/Platform/Images/ImageDerivative.swift \
                           Redcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Redcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Redcast/Features/Clipboard/Model/ColorValue.swift \
                           Redcast/Features/Clipboard/Model/ColorFormat.swift \
                           Redcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Redcast/Features/Clipboard/Service/ClipboardManager.swift \
                           Redcast/Features/Clipboard/Service/Paster.swift
run index clipboard-file-performance \
                           Redcast/Platform/PasteboardFiles.swift \
                           Redcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Redcast/Platform/Images/ImageDerivative.swift \
                           Redcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Redcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Redcast/Features/Clipboard/Model/ColorValue.swift \
                           Redcast/Features/Clipboard/Model/ColorFormat.swift \
                           Redcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Redcast/Features/Clipboard/Service/ClipboardManager.swift
run index clipboard-thumbnail-performance \
                           Redcast/Platform/ProcessExit.swift \
                           Redcast/Platform/Images/ImageThumbnail.swift \
                           Redcast/Platform/Images/ImageDerivative.swift \
                           Redcast/Platform/Images/ThumbnailCache.swift
run emoji-test             Redcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Redcast/Features/Emoji/Model/EmojiGridGeometry.swift \
                           Redcast/Features/Emoji/Model/EmojiData.generated.swift
run emoji-search-test      Redcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Redcast/Features/Emoji/Model/EmojiData.generated.swift \
                           Redcast/Features/Emoji/Service/EmojiIndex.swift \
                           Redcast/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Redcast/Features/Emoji/Service/PinnedEmojiStore.swift \
                           Redcast/Features/Launcher/Model/SearchRelevance.swift \
                           Redcast/Platform/AppPaths.swift Redcast/Platform/Memo.swift
run index emoji-search-performance \
                           Redcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Redcast/Features/Emoji/Model/EmojiData.generated.swift \
                           Redcast/Features/Emoji/Service/EmojiIndex.swift \
                           Redcast/Features/Emoji/Service/FrequentEmojiStore.swift \
                           Redcast/Features/Launcher/Model/SearchRelevance.swift \
                           Redcast/Platform/AppPaths.swift Redcast/Platform/Memo.swift
run palette-selection-test Redcast/Features/PaletteRowIndex.swift \
                           Redcast/Features/Emoji/Model/EmojiGridGeometry.swift
run appearance-test        Redcast/Platform/Appearance.swift \
                           Redcast/DesignSystem/Theme.swift \
                           Redcast/DesignSystem/InterfaceMetrics.swift \
                           Redcast/Features/Settings/AppAppearance.swift
run language-test          Redcast/Features/Settings/AppLanguage.swift
run localized-resource-test Redcast/Platform/LocalizedResource.swift
run exclusive onboarding-test Redcast/Features/Onboarding/OnboardingCoordinator.swift \
                           Redcast/Windows/AppWindowController.swift \
                           Redcast/DesignSystem/Interaction/Motion.swift \
                           Redcast/Windows/WindowChrome.swift Redcast/Platform/ActivationPolicy.swift
run relaunch-test          Redcast/App/AppDelegate.swift Redcast/Platform/RelaunchRunner.swift
run interface-size-test    Redcast/Platform/Appearance.swift \
                           Redcast/DesignSystem/Theme.swift \
                           Redcast/DesignSystem/InterfaceMetrics.swift \
                           Redcast/Features/Settings/InterfaceSize.swift \
                           Redcast/Features/Extensions/Model/ExtensionFormMetrics.swift \
                           Redcast/Windows/HUD/VolumeHUDGeometry.swift
run palette-placement-test Redcast/Platform/Appearance.swift \
                           Redcast/DesignSystem/Theme.swift \
                           Redcast/DesignSystem/InterfaceMetrics.swift \
                           Redcast/Features/Settings/InterfaceSize.swift \
                           Redcast/Palette/PalettePlacement.swift
run palette-menu-click-test Redcast/Platform/Appearance.swift \
                           Redcast/DesignSystem/Theme.swift \
                           Redcast/Platform/WindowLevel.swift \
                           Redcast/Platform/NotificationToken.swift \
                           Redcast/DesignSystem/Interaction/KeyboardFocus.swift \
                           Redcast/DesignSystem/Interaction/Motion.swift \
                           Redcast/DesignSystem/Interaction/AnimatedPanel.swift \
                           Redcast/Palette/PalettePanel.swift
run form-input-test        Redcast/Platform/Appearance.swift \
                           Redcast/DesignSystem/Theme.swift \
                           Redcast/DesignSystem/InterfaceMetrics.swift \
                           Redcast/DesignSystem/FormTextInput.swift \
                           Redcast/DesignSystem/FormTextArea.swift
run scroll-reveal-test     Redcast/DesignSystem/Scrolling/SelectionReveal.swift
run redaction-test         Redcast/DesignSystem/RedactedPlaceholder.swift
run keyboard-focus-test    Redcast/DesignSystem/Interaction/KeyboardFocus.swift
run command-escape-tap-test Redcast/Palette/CommandEscapeTap.swift
run palette-escape-test    Redcast/Palette/PaletteMode.swift \
                           Redcast/Palette/PaletteEscapeAction.swift \
                           Redcast/Palette/CommandEscapeTap.swift \
                           Redcast/Features/Settings/EscapeKeyBehavior.swift \
                           Redcast/Features/Quicklinks/Model/Quicklink.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Redcast/Features/CustomCommands/Model/CustomCommand.swift
run palette-navigation-test Redcast/Palette/PaletteState.swift \
                           Redcast/Palette/PaletteMode.swift \
                           Redcast/Palette/HoverArming.swift \
                           Redcast/Features/Emoji/Model/EmojiCatalog.swift \
                           Redcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Redcast/Platform/Images/ImageDerivative.swift \
                           Redcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Redcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Redcast/Features/FileSearch/Model/FileSearchFilter.swift \
                           Redcast/Features/Clipboard/Model/ColorValue.swift \
                           Redcast/Features/Clipboard/Model/ColorFormat.swift \
                           Redcast/Features/Clipboard/Model/ColorSpaces.swift \
                           Redcast/Features/Quicklinks/Model/Quicklink.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Redcast/Features/CustomCommands/Model/CustomCommand.swift
run palette-filter-test    Redcast/Palette/PaletteMode.swift \
                           Redcast/Palette/PaletteFilterAction.swift \
                           Redcast/Features/Quicklinks/Model/Quicklink.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Redcast/Features/CustomCommands/Model/CustomCommand.swift
run action-menu-search-test Redcast/Palette/ActionMenuSearchQuery.swift \
                            Redcast/Features/Launcher/Model/SearchRelevance.swift
run palette-shortcut-test  Redcast/Palette/PaletteShortcut.swift
run ascii-layout-test      Redcast/Platform/ASCIIKeyboardLayout.swift
run palette-tab-test       Redcast/Palette/PaletteMode.swift \
                           Redcast/Palette/PaletteTabAction.swift \
                           Redcast/Features/Quicklinks/Model/Quicklink.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Redcast/Features/CustomCommands/Model/CustomCommand.swift
run fallback-test          Redcast/Features/Launcher/Model/Fallback.swift \
                           Redcast/Features/Launcher/Model/CommandID.swift \
                           Redcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Redcast/Features/QuickActions/Model/QuickAction.swift \
                           Redcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Redcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Redcast/Features/Quicklinks/Model/Quicklink.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Redcast/Features/SystemActions/Model/SystemAction.swift \
                           Redcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Redcast/Features/Snippets/Model/Snippet.swift \
                           Redcast/Platform/LocalizedResource.swift
# Fork: the tag rules snippets, quicklinks and their editors read; the colour is apart, on the palette.
TAG_RULES="Redcast/Features/Tags/Model/TagList.swift Redcast/Features/Tags/Model/TagFrontmatter.swift \
Redcast/Features/Tags/Model/TagDraft.swift"
# Fork: the Raycast palette, the agent colour rule and the glyph families; ExtensionImage reads it.
FORK_PALETTE="Redcast/DesignSystem/RaycastPalette.swift Redcast/Features/ColorfulIcons/Model/RaycastHue.swift"
run colorful-icons-test    Redcast/Features/ColorfulIcons/Model/*.swift \
                           Redcast/Features/Launcher/Model/CommandID.swift \
                           Redcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Redcast/Features/QuickActions/Model/QuickAction.swift \
                           Redcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Redcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Redcast/Features/Quicklinks/Model/Quicklink.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Redcast/Features/SystemActions/Model/SystemAction.swift \
                           Redcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Redcast/Features/Snippets/Model/Snippet.swift \
                           Redcast/Platform/LocalizedResource.swift
run dictionary-test        Redcast/Features/Dictionary/Model/DictionaryEntry.swift \
                           Redcast/Features/Dictionary/Model/DictionaryMarkup.swift
run dictation-test         Redcast/Features/Dictation/Model/DictationModel.swift Redcast/Features/Dictation/Model/DictationIdleRelease.swift Redcast/Features/Dictation/Model/DictationLanguage.swift Redcast/Features/Dictation/Model/DictationTextFormatter.swift
run dictation-cue-test     Redcast/Features/Dictation/Service/DictationCueRunner.swift
run dictation-field-test   Redcast/Features/Dictation/Model/DictationModel.swift \
                           Redcast/Features/Dictation/Model/DictationAudioChunks.swift \
                           Redcast/Features/Dictation/Model/DictationMode.swift \
                           Redcast/Features/Dictation/Model/DictationDestination.swift \
                           Redcast/Features/Dictation/Model/DictationTextFormatter.swift \
                           Redcast/Features/Dictation/Service/DictationCoordinator.swift \
                           Redcast/Features/Dictation/Service/DictationInsertionContext.swift \
                           Redcast/Features/AI/UI/ChatComposerTextView.swift \
                           Redcast/Features/AI/Model/ChatDraftFacts.swift \
                           Redcast/Features/ChatWorkspace/UI/ChatComposerInk.swift \
                           Redcast/Features/TextInjection/Service/*.swift \
                           Redcast/Features/Snippets/Model/*.swift $TAG_RULES \
                           Redcast/Platform/AccessibilityText.swift \
                           Redcast/Platform/PasteboardFiles.swift \
                           Redcast/Platform/Appearance.swift Redcast/DesignSystem/Theme.swift
run dictation-volume-test  Redcast/Features/Dictation/Model/DictationVolumeSnapshot.swift \
                           Redcast/Features/Dictation/Service/DictationAudioDucker.swift \
                           Redcast/Platform/AppPaths.swift
run index -O dictation-performance Redcast/Platform/ProcessExit.swift \
                           Redcast/Features/Dictation/Model/DictationModel.swift \
                           Redcast/Features/Dictation/Service/DictationWire.swift
run dictation-inference-test Redcast/Features/Dictation/Model/DictationAudioChunks.swift \
    Redcast/Features/Dictation/Service/DictationSpectrum.swift \
    Redcast/Features/Dictation/Helper/DictationTensor.swift Redcast/Features/Dictation/Helper/DictationTokenizer.swift \
    Redcast/Features/Dictation/Helper/DictationMel.swift
run dictation-worker-test  Redcast/Features/Dictation/Model/DictationModel.swift \
                           Redcast/Features/Dictation/Model/DictationIdleRelease.swift \
                           Redcast/Features/Dictation/Service/DictationWire.swift \
                           Redcast/Features/Dictation/Service/DictationWorker.swift \
                           Redcast/Features/Dictation/Service/DictationModelStore.swift \
                           Redcast/Features/Dictation/Service/DictationModelDownloader.swift \
                           Redcast/Platform/ProcessExit.swift Redcast/Platform/AppPaths.swift
run hotkey-test            Redcast/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Redcast/Features/HotKeys/Model/ModifierKey.swift \
                           Redcast/Features/HotKeys/Model/ModifierKeyDetector.swift \
                           Redcast/Features/HotKeys/Model/DoubleTapDetector.swift \
                           Redcast/Features/HotKeys/Model/HotKeyBinding.swift \
                           Redcast/Features/HotKeys/Model/HotKeySpelling.swift \
                           Redcast/Features/HotKeys/Model/HyperKey.swift \
                           Redcast/Features/HotKeys/Model/HIDKeyMapping.swift \
                           Redcast/Platform/ASCIIKeyboardLayout.swift \
                           Redcast/Features/HotKeys/Service/KeyShortcut.swift \
                           Redcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Redcast/Features/QuickActions/Model/QuickAction.swift \
                           Redcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Redcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Redcast/Features/Launcher/Model/CommandID.swift \
                           Redcast/Features/Quicklinks/Model/Quicklink.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Redcast/Features/SystemActions/Model/SystemAction.swift \
                           Redcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Redcast/Features/Snippets/Model/Snippet.swift \
                           Redcast/Platform/LocalizedResource.swift
run callout-test          Redcast/Platform/Appearance.swift \
                           Redcast/DesignSystem/Theme.swift \
                           Redcast/DesignSystem/InterfaceMetrics.swift \
                           Redcast/Features/HotKeys/UI/CalloutPlacement.swift
run icon-cache-test        Redcast/Platform/Appearance.swift \
                           Redcast/Platform/Images/IconCache.swift \
                           Redcast/Platform/Images/TileArtwork.swift
run entry-icon-test        Redcast/Platform/Appearance.swift \
                           Redcast/Platform/Images/IconCache.swift \
                           Redcast/Platform/Images/TileArtwork.swift \
                           Redcast/Platform/Images/FileIconStamp.swift
run ext-icon-test          Redcast/Platform/Appearance.swift \
                           Redcast/Platform/AppDisplayName.swift \
                           Redcast/Platform/Images/IconCache.swift \
                           Redcast/Platform/Images/TileArtwork.swift \
                           Redcast/Platform/Compression/Zlib.swift \
                           Redcast/DesignSystem/Theme.swift \
                           $FORK_PALETTE \
                           Redcast/DesignSystem/InterfaceMetrics.swift \
                           Redcast/Features/Extensions/Model/ExtensionBootConfig.swift \
                           Redcast/Features/Extensions/Model/ExtensionLaunchType.swift \
                           Redcast/Features/Extensions/Model/ExtensionManifest.swift \
                           Redcast/Features/Extensions/Model/ExtensionRefreshPolicy.swift \
                           Redcast/Features/Extensions/Model/ExtensionRefreshState.swift \
                           Redcast/Features/Extensions/Model/RenderNode.swift \
                           Redcast/Features/Extensions/Service/ExtensionCatalog.swift \
                           Redcast/Features/Extensions/Service/ExtensionFetcher.swift \
                           Redcast/Platform/ProcessExit.swift \
                           Redcast/Features/Extensions/Service/ExtensionNodeShims.swift \
                           Redcast/Features/Extensions/Service/ExtensionRuntime.swift \
                           Redcast/Features/Extensions/Service/ExtensionIconCache.swift \
                           Redcast/Features/Extensions/UI/ExtensionAnimatedImage.swift \
                           Redcast/Features/Extensions/UI/ExtensionImage.swift \
                           Redcast/Features/Clipboard/Model/ColorValue.swift \
                           Redcast/Features/Clipboard/Model/ColorSpaces.swift
run system-action-test     Redcast/Features/SystemActions/Model/SystemAction.swift \
                           Redcast/Platform/LocalizedResource.swift
run microphone-mute-test   Redcast/Features/SystemActions/Service/SystemActionFailure.swift \
                           Redcast/Features/SystemActions/Service/SystemActionRunner+Microphone.swift
run volume-test            Redcast/Features/SystemActions/Model/VolumeLevel.swift
run window-command-test    Redcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Redcast/Features/WindowManagement/Model/WindowCycle.swift \
                           Redcast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Redcast/Features/WindowManagement/Model/WindowActionMemory.swift \
                           Redcast/Platform/LocalizedResource.swift
run window-preset-test     Redcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Redcast/Features/WindowManagement/Model/WindowShortcutPreset.swift \
                           Redcast/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Redcast/Features/HotKeys/Model/ModifierKey.swift \
                           Redcast/Features/HotKeys/Model/HotKeyBinding.swift \
                           Redcast/Features/HotKeys/Model/HyperKey.swift \
                           Redcast/Features/HotKeys/Model/HIDKeyMapping.swift \
                           Redcast/Platform/ASCIIKeyboardLayout.swift \
                           Redcast/Features/HotKeys/Service/KeyShortcut.swift \
                           Redcast/Platform/LocalizedResource.swift
run space-gesture-test     Redcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Redcast/Features/WindowManagement/Model/SpaceGesture.swift \
                           Redcast/Platform/LocalizedResource.swift
run window-layout-test     Redcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Redcast/Features/WindowManagement/Model/WindowCycle.swift \
                           Redcast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayout.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayoutPlan.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayoutStore.swift \
                           Redcast/Features/WindowManagement/Model/CustomWindowSize.swift \
                           Redcast/Features/WindowManagement/Model/CustomWindowSizeStore.swift \
                           Redcast/Platform/LocalizedResource.swift
run window-room-test       Redcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Redcast/Features/WindowManagement/Model/WindowCycle.swift \
                           Redcast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayout.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayoutPlan.swift \
                           Redcast/Features/WindowManagement/Model/RoomLayoutKind.swift \
                           Redcast/Features/WindowManagement/Model/RoomLayoutEngine.swift \
                           Redcast/Features/WindowManagement/Model/RoomGrid.swift \
                           Redcast/Features/WindowManagement/Model/RoomWindow.swift \
                           Redcast/Features/WindowManagement/Model/Room.swift \
                           Redcast/Features/WindowManagement/Model/RoomWindowMatcher.swift \
                           Redcast/Features/WindowManagement/Model/RoomParking.swift \
                           Redcast/Features/WindowManagement/Model/RoomPlan.swift \
                           Redcast/Features/WindowManagement/Model/RoomArrangement.swift \
                           Redcast/Features/WindowManagement/Model/RoomStore.swift \
                           Redcast/Features/WindowManagement/Model/RoomMinimumSizeStore.swift \
                           Redcast/Features/WindowManagement/Model/RoomParkingLedger.swift \
                           Redcast/Platform/LocalizedResource.swift
run window-file-test       Redcast/Features/WindowManagement/Model/WindowCommand.swift \
                           Redcast/Features/WindowManagement/Model/WindowCycle.swift \
                           Redcast/Features/WindowManagement/Model/WindowPlacementEngine.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayoutAnchor.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayoutDisplay.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayout.swift \
                           Redcast/Features/WindowManagement/Model/WindowLayoutGeometry.swift \
                           Redcast/Features/WindowManagement/Model/CustomWindowSize.swift \
                           Redcast/Features/WindowManagement/Model/Room.swift \
                           Redcast/Features/WindowManagement/Model/RoomWindow.swift \
                           Redcast/Features/WindowManagement/Model/RoomLayoutKind.swift \
                           Redcast/Features/WindowManagement/Model/RoomGrid.swift \
                           Redcast/Features/WindowManagement/Model/RoomLayoutEngine.swift \
                           Redcast/Features/WindowManagement/Model/WindowManagementFileFormat.swift \
                           Redcast/Features/Settings/Model/SettingsFileJSON.swift \
                           Redcast/Features/Settings/Model/SettingsFileIdentity.swift \
                           Redcast/Platform/LocalizedResource.swift
run custom-command-test    Redcast/Platform/PseudoTerminal.swift \
                           Redcast/Platform/ProcessExit.swift \
                           Redcast/Features/CustomCommands/Model/CustomCommand.swift \
                           Redcast/Features/CustomCommands/Model/RaycastScriptImport.swift \
                           Redcast/Features/CustomCommands/UI/CustomCommandEditorSession.swift \
                           Redcast/Features/CustomCommands/Service/ShellCommandRunner.swift
run custom-command-list-test Redcast/Features/CustomCommands/Model/CustomCommand.swift \
                             Redcast/Features/CustomCommands/UI/CustomCommandListScreen.swift
run uninstall-coordinator-test Redcast/Features/Uninstall/Model/*.swift \
                           Redcast/Features/Uninstall/UI/UninstallCoordinator.swift
run uninstall-test         Redcast/Features/Uninstall/Model/UninstallTarget.swift \
                           Redcast/Features/Uninstall/Model/UninstallSearchRoot.swift \
                           Redcast/Features/Uninstall/Model/UninstallRules.swift \
                           Redcast/Features/Uninstall/Model/UninstallProtection.swift \
                           Redcast/Features/Uninstall/Model/UninstallPlan.swift
run quicklink-test         Redcast/Features/Quicklinks/Model/Quicklink.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkStore.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkArchive.swift \
                           Redcast/Features/Quicklinks/Model/RaycastQuicklinkImport.swift \
                           Redcast/Features/Quicklinks/UI/QuicklinkEditorSession.swift $TAG_RULES
run quicklink-coordinator-test Redcast/Features/Quicklinks/Model/Quicklink.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkStore.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkArchive.swift \
                           Redcast/Features/Quicklinks/UI/QuicklinkCoordinator.swift \
                           Redcast/Features/Quicklinks/UI/QuicklinkEditorSession.swift \
                           Redcast/Features/Quicklinks/UI/QuicklinkArgumentsAccessory.swift \
                           Redcast/Features/Snippets/Model/Snippet.swift \
                           Redcast/Features/Snippets/Model/SnippetTemplateEngine.swift $TAG_RULES
run slow snippets-test     Redcast/Platform/NotificationToken.swift \
                           Redcast/Platform/HealthTicker.swift \
                           Redcast/Platform/AccessibilityText.swift \
                           Redcast/Features/Snippets/Model/*.swift \
                           Redcast/Features/Snippets/Service/*.swift \
                           Redcast/Features/Snippets/UI/SnippetEditorSession.swift $TAG_RULES \
                           Redcast/Features/TextInjection/Service/*.swift
# Fork: tags on snippets and quicklinks: frontmatter, the store's column, imports, filter and colour.
run bundle-migration-test  Redcast/Features/BundleMigration/Model/*.swift
# Fork: Redcast's name outside the catalogs, both URL schemes and both backup extensions.
run tags-test              Redcast/Features/Tags/Model/*.swift \
                           Redcast/Features/ColorfulIcons/Model/RaycastHue.swift \
                           Redcast/Features/Snippets/Model/Snippet.swift \
                           Redcast/Features/Snippets/Model/SnippetMarkdownSerializer.swift \
                           Redcast/Features/Snippets/Model/RaycastSnippetImport.swift \
                           Redcast/Features/Quicklinks/Model/Quicklink.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkDestination.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkStore.swift \
                           Redcast/Features/Quicklinks/Model/QuicklinkArchive.swift \
                           Redcast/Features/Quicklinks/Model/RaycastQuicklinkImport.swift
run notes-test             Redcast/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Redcast/Features/Notes/Model/*.swift \
                           Redcast/Features/Notes/Service/*.swift
run notes-ai-test          Redcast/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Redcast/Features/Notes/Model/*.swift \
                           Redcast/Features/Notes/Service/*.swift \
                           Redcast/Features/Agents/Model/*.swift \
                           Redcast/Features/WebSearch/Model/*.swift \
                           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Redcast/Features/AI/Model/InstalledAI.swift \
                           Redcast/Features/NotesAI/Model/*.swift \
                           Redcast/Features/NotesAI/Service/*.swift
run notes-editor-test      Redcast/Platform/Signposts.swift \
                           Redcast/Platform/Appearance.swift \
                           Redcast/DesignSystem/Theme.swift \
                           Redcast/DesignSystem/InterfaceMetrics.swift \
                           Redcast/Platform/NotificationToken.swift \
                           Redcast/Features/TextInjection/Service/InjectableTextView.swift \
                           Redcast/Features/Notes/Model/NoteDocument.swift \
                           Redcast/Features/Notes/Model/NoteTitle.swift \
                           Redcast/Features/Notes/Model/NoteMarkdown.swift \
                           Redcast/Features/Notes/Model/NoteMarkdownParser.swift \
                           Redcast/Features/Notes/Model/NoteInlineScanner.swift \
                           Redcast/Features/Notes/Model/NoteEditPlan.swift \
                           Redcast/Features/Notes/Model/NoteEditAction.swift \
                           Redcast/Features/Notes/Model/NoteFormatting.swift \
                           Redcast/Features/Notes/Model/NoteMarkdownEditing.swift \
                           Redcast/Features/Notes/Model/NoteRevealPolicy.swift \
                           Redcast/Features/Notes/UI/NoteMarkdownTypography.swift \
                           Redcast/Features/Notes/UI/NoteBlockDecoration.swift \
                           Redcast/Features/Notes/UI/NoteMarkdownStyler.swift \
                           Redcast/Features/Notes/UI/NoteMarkdownRenderer.swift \
                           Redcast/Features/Notes/UI/NoteCheckboxGeometry.swift \
                           Redcast/Features/Notes/UI/NoteBlockLayoutFragment.swift \
                           Redcast/Features/Notes/UI/NoteLayoutFragmentProvider.swift \
                           Redcast/Features/Notes/UI/NoteTextViewEditing.swift \
                           Redcast/Features/Notes/UI/NoteTextView.swift \
                           Redcast/Features/Notes/UI/NoteEditorView.swift
run -O index notes-editor-performance \
                           Redcast/Platform/Signposts.swift \
                           Redcast/Platform/Appearance.swift \
                           Redcast/DesignSystem/Theme.swift \
                           Redcast/DesignSystem/InterfaceMetrics.swift \
                           Redcast/Platform/NotificationToken.swift \
                           Redcast/Features/TextInjection/Service/InjectableTextView.swift \
                           Redcast/Features/Notes/Model/NoteDocument.swift \
                           Redcast/Features/Notes/Model/NoteTitle.swift \
                           Redcast/Features/Notes/Model/NoteMarkdown.swift \
                           Redcast/Features/Notes/Model/NoteMarkdownParser.swift \
                           Redcast/Features/Notes/Model/NoteInlineScanner.swift \
                           Redcast/Features/Notes/Model/NoteEditPlan.swift \
                           Redcast/Features/Notes/Model/NoteEditAction.swift \
                           Redcast/Features/Notes/Model/NoteFormatting.swift \
                           Redcast/Features/Notes/Model/NoteMarkdownEditing.swift \
                           Redcast/Features/Notes/Model/NoteRevealPolicy.swift \
                           Redcast/Features/Notes/UI/NoteMarkdownTypography.swift \
                           Redcast/Features/Notes/UI/NoteBlockDecoration.swift \
                           Redcast/Features/Notes/UI/NoteMarkdownStyler.swift \
                           Redcast/Features/Notes/UI/NoteMarkdownRenderer.swift \
                           Redcast/Features/Notes/UI/NoteCheckboxGeometry.swift \
                           Redcast/Features/Notes/UI/NoteBlockLayoutFragment.swift \
                           Redcast/Features/Notes/UI/NoteLayoutFragmentProvider.swift \
                           Redcast/Features/Notes/UI/NoteTextViewEditing.swift \
                           Redcast/Features/Notes/UI/NoteTextView.swift \
                           Redcast/Features/Notes/UI/NoteEditorView.swift
run slow -O raycast-test   Redcast/Features/Backup/Model/RaycastImportError.swift \
                           Redcast/Features/Backup/Service/RaycastDecoder.swift \
                           Redcast/Features/Backup/Service/Scrypt.swift \
                           Redcast/Platform/Compression/Zlib.swift \
                           Redcast/Features/Clipboard/Model/RaycastClipboardImport.swift \
                           Redcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Redcast/Platform/Images/ImageDerivative.swift \
                           Redcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Redcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Redcast/Features/Clipboard/Model/ColorValue.swift \
                           Redcast/Features/Clipboard/Model/ColorFormat.swift \
                           Redcast/Features/Clipboard/Model/ColorSpaces.swift
run settings-backup-test   Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/Backup/Model/SettingsBackupCoverage.swift
run hyper-key-test         Redcast/Features/HotKeys/Model/HIDKeyMapping.swift \
                           Redcast/Features/HotKeys/Model/HyperKeyConflictPolicy.swift \
                           Redcast/Features/HotKeys/Service/KeyboardRemapper.swift \
                           Tests/hyper-key-fixtures.swift
run hotkey-dispatch-test   Redcast/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Redcast/Features/HotKeys/Model/ModifierKey.swift \
                           Redcast/Features/HotKeys/Model/HotKeyBinding.swift \
                           Redcast/Features/HotKeys/Model/HyperKey.swift \
                           Redcast/Features/HotKeys/Model/HIDKeyMapping.swift \
                           Redcast/Features/HotKeys/Model/HotKeyAction.swift \
                           Redcast/Features/HotKeys/Service/KeyShortcut.swift \
                           Redcast/Features/HotKeys/Service/HotKeyManager.swift \
                           Redcast/Platform/ASCIIKeyboardLayout.swift \
                           Tests/hotkey-dispatch-fixtures.swift
run settings-file-test     Redcast/Features/Settings/Model/*.swift \
                           Redcast/Features/Settings/Service/SettingsFileMonitor.swift \
                           Redcast/Features/Settings/Service/SettingsFileRepository.swift \
                           Redcast/Platform/AppPaths.swift
run backup-archive-test    Redcast/Platform/AppPaths.swift \
                           Redcast/Features/Backup/Model/BackupArchive.swift \
                           Redcast/Features/Backup/Model/BackupBundle.swift \
                           Redcast/Features/Backup/Model/BackupCategory.swift \
                           Redcast/Features/Backup/Model/BackupClipboardItem.swift \
                           Redcast/Features/Backup/Model/BackupManifest.swift \
                           Redcast/Features/Backup/Service/BackupStaging.swift
# Fork: the full backup's sections, version tolerance, import rules, sealed secrets and auto export.
FB=Redcast/Features/FullBackup
run full-backup-test       $FB/Model/*.swift $FB/Service/FullBackupCipher.swift \
                           $FB/Service/FullBackupChatArchive.swift \
                           Redcast/Features/Agents/Model/*.swift Redcast/Features/WebSearch/Model/*.swift \
                           Redcast/Features/AI/Model/*.swift Redcast/Features/ReasoningReplay/Model/*.swift \
                           Redcast/Features/AI/Service/AIProvider.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift Redcast/Features/MCP/Model/*.swift \
                           Redcast/Features/VoiceAI/Model/*.swift \
                           Redcast/Features/Dictation/Model/DictationLanguage.swift \
                           Redcast/Features/Dictation/Model/DictationMode.swift \
                           Redcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Redcast/Features/Extensions/Model/ExtensionAppearance.swift \
                           Redcast/Features/HotKeys/Model/HotKeyBinding.swift \
                           Redcast/Features/HotKeys/Model/ModifierKey.swift \
                           Redcast/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Redcast/Features/HotKeys/Model/HyperKey.swift \
                           Redcast/Features/HotKeys/Model/HIDKeyMapping.swift \
                           Redcast/Features/HotKeys/Service/KeyShortcut.swift \
                           Redcast/Platform/ASCIIKeyboardLayout.swift Redcast/Platform/AppPaths.swift \
                           Redcast/Features/Backup/Model/BackupArchive.swift \
                           Redcast/Features/Backup/Model/BackupBundle.swift \
                           Redcast/Features/Backup/Model/BackupCategory.swift \
                           Redcast/Features/Backup/Model/BackupClipboardItem.swift \
                           Redcast/Features/Backup/Model/BackupManifest.swift
# Fork: every store the app persists has a full backup decision; it scans the sources.
run full-backup-coverage-test Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/Backup/Model/SettingsBackupCoverage.swift \
                           $FB/Model/FullBackupSection.swift $FB/Model/FullBackupConsent.swift \
                           $FB/Model/FullBackupCoverage.swift
# Fork: the Shortcuts overview's conflict audit, filters and system shortcuts.
run shortcuts-overview-test Redcast/Features/ShortcutsOverview/Model/*.swift \
                           Redcast/Features/HotKeys/Model/HotKeyBinding.swift \
                           Redcast/Features/HotKeys/Model/ModifierKey.swift \
                           Redcast/Features/HotKeys/Model/DoubleTapModifier.swift \
                           Redcast/Features/HotKeys/Model/HyperKey.swift \
                           Redcast/Features/HotKeys/Model/HIDKeyMapping.swift \
                           Redcast/Features/HotKeys/Service/KeyShortcut.swift \
                           Redcast/Platform/ASCIIKeyboardLayout.swift
E=Redcast/Features/Extensions
run symbols-test           $E/Service/SymbolCatalog.swift
run ext-cleanup-test       $E/Service/ExtensionCleanup.swift \
                           $E/Service/ExtensionCatalog.swift \
                           Redcast/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-refresh-test       $E/Model/ExtensionManifest.swift \
                           Redcast/Platform/AppDisplayName.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift
run ext-metadata-test      $E/Model/ExtensionCommandMetadata.swift \
                           $E/Model/ExtensionMenuBarSnapshot.swift \
                           $E/Service/ExtensionCommandMetadataStore.swift
run ext-version-test       $E/Model/ExtensionListing.swift \
                           $E/Service/ExtensionVersionStore.swift
run ext-store-test         $E/Model/ExtensionGitHubSource.swift \
                           $E/Model/ExtensionListing.swift \
                           $E/Model/ExtensionPackageManager.swift \
                           $E/Model/ExtensionStoreResponse.swift
run ext-form-test          $E/Model/ExtensionFormMetrics.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/UI/ExtensionFormKey.swift \
                           $E/Model/ExtensionDateExpression.swift \
                           $E/UI/ExtensionListKey.swift \
                           Tests/ext-list-key-test.swift
run ext-image-size-test   $E/Model/ExtensionImageSize.swift
run ext-accessory-test     $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionStorage.swift
run slow ext-test          -parse-as-library \
                           Tests/ext-menu-bar-test.swift \
                           Tests/ext-fetch-test.swift \
                           Tests/ext-ai-bridge-test.swift \
                           $E/Service/ExtensionHostBridge.swift \
                           $E/Service/ExtensionSignInSession.swift \
                           Redcast/Features/ExtensionAI/Service/ExtensionAIHost.swift \
                           Redcast/Features/Launcher/Service/AppLauncher.swift \
                           Redcast/Platform/AccessibilityText.swift \
                           Redcast/Platform/PasteboardFiles.swift \
                           Redcast/Platform/Images/ImageDerivative.swift \
                           Redcast/Features/Clipboard/Model/ClipboardStore.swift \
                           Redcast/Features/Clipboard/Model/ClipboardFilter.swift \
                           Redcast/Features/Clipboard/Model/ClipboardFileKind.swift \
                           Redcast/Features/Clipboard/Model/ColorFormat.swift \
                           Redcast/Features/Clipboard/Service/ClipboardManager.swift \
                           Redcast/Features/Clipboard/Service/Paster.swift \
                           $E/Model/ExtensionLaunchError.swift \
                           $E/Model/ExtensionMenuBarSnapshot.swift \
                           $E/Service/ExtensionStorage.swift \
                           $E/Service/ExtensionMenuBarManager.swift \
                           $E/Model/ExtensionCommandMetadata.swift \
                           $E/Service/ExtensionCommandMetadataStore.swift \
                           $E/UI/ExtensionMenuBarController.swift \
                           $E/UI/ExtensionMenuBarImage.swift \
                           Redcast/Platform/Appearance.swift \
                           Redcast/Platform/AppDisplayName.swift \
                           Redcast/Platform/Images/IconCache.swift \
                           Redcast/Platform/Images/TileArtwork.swift \
                           Redcast/DesignSystem/Theme.swift \
                           $FORK_PALETTE \
                           Redcast/DesignSystem/InterfaceMetrics.swift \
                           $E/Model/ExtensionBootConfig.swift \
                           $E/Model/ExtensionDeepLink.swift \
                           $E/Model/ExtensionLaunchType.swift \
                           $E/Model/ExtensionFormField.swift \
                           $E/Model/ExtensionGridLayout.swift \
                           $E/Model/ExtensionSearchState.swift \
                           $E/Model/ExtensionManifest.swift \
                           $E/Model/ExtensionRefreshPolicy.swift \
                           $E/Model/ExtensionRefreshState.swift \
                           $E/Model/RenderNode.swift \
                           $E/Model/ExtensionPickerItem.swift \
                           $E/Model/ExtensionSearchAccessory.swift \
                           $E/Service/ExtensionCatalog.swift \
                           $E/Service/ExtensionFetcher.swift \
                           Redcast/Platform/ProcessExit.swift \
                           $E/Service/ExtensionIconCache.swift \
                           $E/Service/ExtensionNodeShims.swift \
                           $E/Service/ExtensionRuntime.swift \
                           $E/Service/ExtensionNameResolver.swift \
                           $E/Service/ExtensionWebSocketBridge.swift \
                           $E/UI/ExtensionAnimatedImage.swift \
                           $E/UI/ExtensionImage.swift \
                           $E/UI/ExtensionScreen.swift \
                           $L/SearchRelevance.swift \
                           Redcast/Platform/Compression/Zlib.swift \
                           Redcast/Features/Clipboard/Model/ColorValue.swift \
                           Redcast/Features/Clipboard/Model/ColorSpaces.swift
run settings-history-test  Redcast/Features/Settings/SettingsTab.swift \
                           Redcast/Features/Settings/SettingsHistory.swift \
                           Redcast/Features/Settings/SettingsAnchor.swift \
                           Redcast/Features/Settings/SettingsNavigationState.swift \
                           Redcast/Features/Settings/SettingsSearchCatalog.swift \
                           $L/SearchRelevance.swift \
                           Redcast/Platform/LocalizedResource.swift
run updates-test           Redcast/Features/Updates/Model/*.swift \
                           Redcast/Features/Updates/Service/BundleSignature.swift
run update-check-test      Redcast/Features/Updates/Model/*.swift \
                           Redcast/Features/Updates/Service/UpdateCheckStore.swift \
                           Redcast/Platform/AppPaths.swift
run ai-provider-test       Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/*.swift \
                           Redcast/Features/ReasoningReplay/Model/*.swift \
                           Redcast/Features/Agents/Model/ChatToolContent.swift \
                           Redcast/Features/AI/Settings/AISettingsStore.swift
run ai-model-catalog-test  Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/*.swift \
                           Redcast/Features/ReasoningReplay/Model/*.swift \
                           Redcast/Features/Agents/Model/ChatToolContent.swift
run ai-chat-test           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/Agents/Model/ChatToolContent.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AIConversationOpenPolicy.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Redcast/Features/AI/Model/AIRetention.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/AI/Model/ChatMessage.swift \
                           Redcast/Features/AI/Model/ChatSession.swift \
                           Redcast/Features/AI/Model/ChatChoices.swift \
                           Redcast/Features/AI/Model/ChatReferences.swift \
                           Redcast/Features/AI/Model/ChatTitle.swift \
                           Redcast/Features/AI/Model/ChatFind.swift \
                           Redcast/Features/AI/Model/ChatCitations.swift \
                           Redcast/Features/AI/Model/ChatToolScope.swift \
                           Redcast/Features/AI/Model/MarkdownBlock.swift \
                           Redcast/Features/AI/Model/MarkdownMath.swift \
                           Redcast/Features/AI/Model/MathFormula.swift \
                           Redcast/Features/AI/Model/MathNode.swift \
                           Redcast/Features/AI/Model/MathSymbolCatalog.swift \
                           Redcast/Features/AI/Service/AIProvider.swift \
                           Redcast/Features/AI/Service/ChatHistoryStore.swift \
                           Redcast/Features/AI/Service/AIToolLoopProvider.swift \
                           Redcast/Features/WebSearch/Model/*.swift \
                           Redcast/Features/AI/Model/ChatDraftFacts.swift \
                           Redcast/Features/AI/UI/AIChatState.swift \
                           Redcast/Features/AI/UI/AIChatSurfacesState.swift \
                           Redcast/Features/AI/UI/ChatFindState.swift
run chat-markdown-test     Redcast/Platform/Appearance.swift \
                           Redcast/DesignSystem/Theme.swift \
                           Redcast/DesignSystem/InterfaceMetrics.swift \
                           Redcast/Features/Settings/InterfaceSize.swift \
                           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/Agents/Model/ChatToolContent.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/AI/Model/ChatMessage.swift \
                           Redcast/Features/AI/Model/ChatChoices.swift \
                           Redcast/Features/AI/Model/ChatReferences.swift \
                           Redcast/Features/AI/Model/ChatCitations.swift \
                           Redcast/Features/AI/Model/ChatFind.swift \
                           Redcast/Features/AI/Model/MarkdownBlock.swift \
                           Redcast/Features/AI/Model/MarkdownMath.swift \
                           Redcast/Features/AI/Model/MathFormula.swift \
                           Redcast/Features/AI/Model/MathNode.swift \
                           Redcast/Features/AI/Model/MathSymbolCatalog.swift \
                           Redcast/Features/AI/Model/SyntaxGrammar.swift \
                           Redcast/Features/AI/Model/SyntaxHighlighter.swift \
                           Redcast/Features/AI/Model/SyntaxStructuredLexers.swift \
                           Redcast/Features/AI/UI/ChatTextHighlight.swift \
                           Redcast/Features/AI/UI/ChatMarkdownRenderer.swift \
                           Redcast/Features/ChatFiles/Model/*.swift \
                           Redcast/Features/ChatFiles/UI/ChatFileLinker.swift \
                           Redcast/Features/AI/UI/MathAttachmentCell.swift \
                           Redcast/Features/AI/UI/MathBox.swift \
                           Redcast/Features/AI/UI/MathFont.swift \
                           Redcast/Features/AI/UI/MathLayoutEngine.swift
run chat-files-test        Redcast/Features/ChatFiles/Model/*.swift \
                           Redcast/Features/ChatFiles/Service/ChatAttachmentFiles.swift
CW=Redcast/Features/ChatWorkspace
run chat-workspace-test    $CW/Model/*.swift $CW/Service/*.swift $CW/Settings/ChatWorkspaceSettings.swift \
                           $CW/UI/ChatWorkspaceHost.swift $CW/UI/ChatWorkspaceCoordinator.swift $CW/UI/ChatSettingsState.swift \
                           $CW/UI/ChatWorkspaceCoordinator+Selection.swift $CW/UI/ChatWindowRelease.swift \
                           Redcast/Features/ColorfulIcons/Model/RaycastHue.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/Agents/Model/ChatToolContent.swift \
                           Redcast/Features/Agents/Model/ChatAccess.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AIModelCatalog.swift \
                           Redcast/Features/AI/Model/AIModelCatalogData.generated.swift \
                           Redcast/Features/AI/Model/AIConversationOpenPolicy.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Redcast/Features/AI/Model/AIRetention.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/AI/Model/ChatMessage.swift \
                           Redcast/Features/AI/Model/ChatSession.swift \
                           Redcast/Features/AI/Model/ChatChoices.swift \
                           Redcast/Features/AI/Model/ChatToolScope.swift \
                           Redcast/Features/AI/Service/AIProvider.swift \
                           Redcast/Features/AI/Service/ChatHistoryStore.swift \
                           Redcast/Features/AI/Model/ChatDraftFacts.swift \
                           Redcast/Features/AI/UI/AIChatState.swift \
                           Redcast/Features/AI/UI/AIChatSurfacesState.swift
run syntax-highlight-test  Redcast/Features/AI/Model/SyntaxGrammar.swift \
                           Redcast/Features/AI/Model/SyntaxHighlighter.swift \
                           Redcast/Features/AI/Model/SyntaxStructuredLexers.swift
run mcp-test               Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/AIToolServer.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/MCP/Model/*.swift Redcast/Features/Agents/Model/ChatAccess.swift \
                           Redcast/Features/MCP/Settings/MCPSettingsStore.swift
run -O text-diff-test      Redcast/Features/QuickActions/Model/TextDiffEngine.swift
run index text-diff-performance Redcast/Features/QuickActions/Model/TextDiffEngine.swift
run screen-awareness-test  Redcast/Features/ScreenAwareness/Model/*.swift \
                           Redcast/Features/ScreenAwareness/Service/ScreenAgentTools.swift \
                           Redcast/Features/ScreenAwareness/Service/ScreenContextReader.swift \
                           Redcast/Platform/AccessibilityText.swift \
                           Redcast/Features/Agents/Model/*.swift \
                           Redcast/Features/WebSearch/Model/*.swift \
                           Redcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Redcast/Features/AI/Model/InstalledAI.swift
run voice-ai-test          Redcast/Features/VoiceAI/Model/*.swift \
                           Redcast/Features/Dictation/Model/DictationLanguage.swift \
                           Redcast/Features/Agents/Model/ChatToolContent.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/*.swift \
                           Redcast/Features/ReasoningReplay/Model/*.swift \
                           Redcast/Features/AI/Settings/AISettingsStore.swift
run voice-coordinator-test Redcast/Features/VoiceAI/Model/*.swift \
                           Redcast/Features/Agents/Model/ChatToolContent.swift \
                           Redcast/Features/VoiceAI/Service/VoiceCloudTranscriber.swift \
                           Redcast/Features/VoiceAI/Service/VoiceMediaEncoder.swift \
                           Redcast/Features/VoiceAI/Settings/VoiceAISettings.swift \
                           Redcast/Features/VoiceAI/UI/VoiceAskCoordinator.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/*.swift \
                           Redcast/Features/ReasoningReplay/Model/*.swift \
                           Redcast/Features/AI/Service/AIProvider.swift \
                           Redcast/Features/AI/Settings/AISettingsStore.swift \
                           Redcast/Features/Dictation/Model/DictationMode.swift \
                           Redcast/Features/Dictation/Model/DictationLanguage.swift \
                           Redcast/Platform/SystemLanguages.swift \
                           Redcast/Features/ScreenAwareness/Model/*.swift \
                           Redcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Redcast/Features/QuickActions/Model/QuickActionFailure.swift \
                           Redcast/Features/DictationHistory/Model/DictationHistoryEntry.swift \
                           Redcast/Features/DictationHistory/Model/DictationRetry.swift
# Fork: Dictation History's line format, file, search, kept recordings and retries.
run dictation-history-test Redcast/Features/DictationHistory/Model/*.swift \
                           Redcast/Features/DictationHistory/Service/DictationHistoryFile.swift \
                           Redcast/Features/DictationHistory/Service/DictationRecordingFolder.swift \
                           Redcast/Features/VoiceAI/Model/VoiceAudio.swift \
                           Redcast/Platform/AppPaths.swift
# Fork: what Send to AI hands Quick AI or a new chat for each kind of row.
run send-to-ai-test        Redcast/Features/SendToAI/Model/*.swift \
                           Redcast/Features/Clipboard/Model/ColorValue.swift \
                           Redcast/Features/Clipboard/Model/ColorFormat.swift \
                           Redcast/Features/Clipboard/Model/ColorSpaces.swift
# Fork: the Extension Store's three endpoints, cache, shelves, categories, search and install state.
run extension-store-test   Redcast/Features/ExtensionStore/Model/*.swift \
                           Redcast/Features/ExtensionStore/Service/ExtensionStoreCache.swift \
                           $L/SearchRelevance.swift \
                           Redcast/Features/Extensions/Model/ExtensionListing.swift \
                           Redcast/Features/Extensions/Model/ExtensionStoreResponse.swift \
                           Redcast/Platform/AppPaths.swift
run alias-actions-test     Redcast/Features/AliasActions/Model/*.swift
run acp-test               Redcast/Features/Agents/Model/*.swift \
                           Redcast/Features/WebSearch/Model/*.swift \
                           Redcast/Features/WebSearch/Service/WebPageReader.swift \
                           Redcast/Features/DocumentText/Model/*.swift \
                           Redcast/Features/DocumentText/Service/*.swift \
                           Redcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Redcast/Features/Agents/Service/*.swift \
                           Redcast/Platform/NotificationToken.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/AI/Model/AIToolServer.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Redcast/Features/AI/Model/InstalledAI.swift \
                           Redcast/Features/AI/Service/AIProvider.swift \
                           Redcast/Platform/ExecutableLocator.swift \
                           Redcast/Platform/PseudoTerminal.swift \
                           Redcast/Platform/ProcessExit.swift \
                           Redcast/Features/CustomCommands/Service/ShellCommandRunner.swift
run agent-tools-test       Redcast/Features/Agents/Model/*.swift \
                           Redcast/Features/WebSearch/Model/*.swift \
                           Redcast/Features/WebSearch/Service/WebPageReader.swift \
                           Redcast/Features/DocumentText/Model/*.swift \
                           Redcast/Features/DocumentText/Service/*.swift \
                           Redcast/Features/DocumentText/Helper/*.swift \
                           Redcast/Features/Clipboard/Service/ClipboardTextExtractor.swift \
                           Redcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/AI/Model/AIToolServer.swift \
                           Redcast/Features/AI/Service/AIProvider.swift \
                           Redcast/Platform/ExecutableLocator.swift \
                           Redcast/Features/Agents/Service/*.swift \
                           Redcast/Platform/NotificationToken.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Redcast/Features/AI/Model/InstalledAI.swift \
                           Redcast/Platform/PseudoTerminal.swift \
                           Redcast/Platform/ProcessExit.swift \
                           Redcast/Features/CustomCommands/Service/ShellCommandRunner.swift
run agent-test             Redcast/Features/Agents/Model/*.swift \
                           Redcast/Features/WebSearch/Model/*.swift \
                           Redcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Redcast/Features/AI/Model/InstalledAI.swift
# Fork: skills read from four folders by precedence, the per-agent selection and the prompt.
run agent-skills-test      Redcast/Features/Agents/Model/*.swift \
                           Redcast/Features/Agents/Service/AgentContextLoader.swift \
                           Redcast/Features/WebSearch/Model/*.swift \
                           Redcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Redcast/Features/AI/Model/InstalledAI.swift
run agent-schedule-test    Redcast/Features/Agents/Model/*.swift \
                           Redcast/Features/WebSearch/Model/*.swift \
                           Redcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Redcast/Features/Agents/Service/AgentScheduler.swift \
                           Redcast/Features/Agents/UI/AgentConsentGate.swift \
                           Redcast/Features/Agents/UI/AgentNoteWriter.swift \
                           Redcast/Platform/Signposts.swift \
                           $L/SearchRelevance.swift \
                           Redcast/Features/Notes/Model/*.swift \
                           Redcast/Features/Notes/Service/*.swift \
                           Redcast/Platform/NotificationToken.swift \
                           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Redcast/Features/AI/Model/InstalledAI.swift
run agent-loop-test        Redcast/Features/Agents/Model/*.swift \
                           Redcast/Features/Agents/Service/AgentLoopProvider.swift \
                           Redcast/Features/Agents/Service/AgentDelegateTools.swift \
                           Redcast/Features/Agents/Service/AgentSpendMeter.swift \
                           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Redcast/Features/AI/Model/InstalledAI.swift \
                           Redcast/Features/AI/Service/AIProvider.swift \
                           Redcast/Features/AI/Service/AIToolLoopProvider.swift \
                           Redcast/Features/WebSearch/Model/*.swift \
                           Redcast/Features/AI/Model/AIAttachmentPolicy.swift
# Fork: the native agent end to end, real loop and tools on each provider's wire; it is its own helper.
run agent-scenario-test    Redcast/Features/Agents/Model/*.swift \
                           Redcast/Features/Agents/Service/*.swift \
                           Redcast/Features/AI/Model/*.swift \
                           Redcast/Features/ReasoningReplay/Model/*.swift \
                           Redcast/Features/AI/Service/AIProvider.swift \
                           Redcast/Features/WebSearch/Model/*.swift \
                           Redcast/Features/WebSearch/Service/*.swift \
                           Redcast/Features/DocumentText/Model/*.swift \
                           Redcast/Features/DocumentText/Service/*.swift \
                           Redcast/Features/DocumentText/Helper/*.swift \
                           Redcast/Features/Clipboard/Service/ClipboardTextExtractor.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Platform/NotificationToken.swift \
                           Redcast/Platform/ExecutableLocator.swift \
                           Redcast/Platform/PseudoTerminal.swift \
                           Redcast/Platform/ProcessExit.swift \
                           Redcast/Features/CustomCommands/Service/ShellCommandRunner.swift
run web-search-test        Redcast/Features/WebSearch/Model/*.swift \
                           Redcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Redcast/Features/WebSearch/Service/*.swift \
                           Redcast/Features/DocumentText/Model/*.swift \
                           Redcast/Features/DocumentText/Service/*.swift \
                           Redcast/Features/DocumentText/Helper/*.swift \
                           Redcast/Features/Clipboard/Service/ClipboardTextExtractor.swift \
                           Redcast/Platform/ProcessExit.swift \
                           Redcast/Features/Agents/Service/AgentWebRounds.swift \
                           Redcast/Features/Agents/Model/*.swift \
                           Redcast/Features/Agents/Service/AgentLoopProvider.swift \
                           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Redcast/Features/AI/Model/InstalledAI.swift \
                           Redcast/Features/AI/Service/AIProvider.swift \
                           Redcast/Features/AI/Service/AIToolLoopProvider.swift
run quick-ai-tools-test    Redcast/Features/QuickAITools/Model/*.swift \
                           Redcast/Features/Agents/Settings/AgentDefaultStore.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/WebSearch/Model/*.swift \
                           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/Agents/Model/ChatToolContent.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Redcast/Features/AI/Model/InstalledAI.swift
run ext-ai-test            Redcast/Features/ExtensionAI/Model/*.swift \
                           Redcast/Features/Agents/Model/ChatToolContent.swift \
                           Redcast/Features/ExtensionAI/Service/*.swift \
                           Redcast/Features/ExtensionAI/Settings/ExtensionAISettingsStore.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/Extensions/Model/RenderNode.swift \
                           Redcast/Features/AI/Model/*.swift \
                           Redcast/Features/ReasoningReplay/Model/*.swift \
                           Redcast/Features/AI/Settings/AISettingsStore.swift \
                           Redcast/Features/AI/Service/AIProvider.swift
run usage-dashboard-test   Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/Agents/Model/ChatToolContent.swift \
                           Redcast/Features/AI/Model/AIRequestBody.swift \
                           Redcast/Features/ReasoningReplay/Model/*.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Redcast/Features/AI/Model/InstalledAI.swift \
                           Redcast/Features/AI/Model/AIAttachmentPolicy.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/AI/Model/ChatMessage.swift \
                           Redcast/Features/AI/Model/ChatSession.swift \
                           Redcast/Features/AI/Model/ChatChoices.swift \
                           Redcast/Features/AI/Service/AIProvider.swift \
                           Redcast/Features/AI/Service/ChatHistoryStore.swift \
                           Redcast/Features/AI/Service/AIToolLoopProvider.swift \
                           Redcast/Features/WebSearch/Model/*.swift \
                           Redcast/Features/UsageDashboard/Model/*.swift \
                           Redcast/Features/UsageDashboard/Service/UsageQuery.swift \
                           Redcast/Features/UsageDashboard/Service/UsageLedger.swift \
                           Redcast/Features/UsageDashboard/Service/UsageRecordingProvider.swift \
                           Redcast/Platform/AppPaths.swift
run codex-plan-test        Redcast/Features/CodexProvider/Model/*.swift \
                           Redcast/Features/AI/Model/*.swift \
                           Redcast/Features/ReasoningReplay/Model/*.swift \
                           Redcast/Features/Agents/Model/ChatToolContent.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift
AS=Redcast/Features/AgentSessions
run slow agent-sessions-test $L/SearchRelevance.swift $AS/Model/*.swift \
                           $AS/Service/AgentSessionsScanner.swift $AS/Service/AgentTranscriptSearch.swift \
                           $AS/Service/AgentHookRepository.swift $AS/Service/ClaudeLiveSessionsProbe.swift \
                           Redcast/Features/Agents/Service/ProcessTree.swift \
                           Redcast/Platform/ExecutableLocator.swift Redcast/Platform/ProcessExit.swift
run index agent-sessions-performance $L/SearchRelevance.swift $AS/Model/*.swift
run quick-action-test      Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Redcast/Features/AI/Model/InstalledAI.swift \
                           Redcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Redcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Redcast/Features/QuickActions/Model/CustomQuickActionStore.swift \
                           Redcast/Features/QuickActions/Model/QuickAction.swift \
                           Redcast/Features/QuickActions/Model/QuickActionFailure.swift \
                           Redcast/Features/QuickActions/Model/QuickActionPrompt.swift \
                           Redcast/Features/QuickActions/Model/QuickActionSettings.swift \
                           Redcast/Features/QuickActions/Model/QuickActionTemplate.swift \
                           Redcast/Features/Snippets/Model/Snippet.swift \
                           Redcast/Features/Snippets/Model/SnippetTemplateEngine.swift \
                           Redcast/Features/QuickActions/Settings/QuickActionSettingsStore.swift \
                           Redcast/Features/QuickActionModels/Model/QuickActionRoutes.swift \
                           Redcast/Platform/LocalizedResource.swift
# Fork: a custom action's own model: persisted per entry, and the default when its connection goes.
run quick-action-model-test Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/ChatGPTSubscription.swift \
                           Redcast/Features/AI/Model/InstalledAI.swift \
                           Redcast/Features/QuickActions/Model/BuiltInQuickAction.swift \
                           Redcast/Features/QuickActions/Model/CustomQuickAction.swift \
                           Redcast/Features/QuickActions/Model/QuickAction.swift \
                           Redcast/Features/QuickActions/Model/QuickActionSettings.swift \
                           Redcast/Features/QuickActions/Settings/QuickActionSettingsStore.swift \
                           Redcast/Features/QuickActionModels/Model/QuickActionRoutes.swift \
                           Redcast/Platform/LocalizedResource.swift
run apple-intelligence-test Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/*.swift \
                           Redcast/Features/ReasoningReplay/Model/*.swift \
                           Redcast/Features/Agents/Model/ChatToolContent.swift \
                           Redcast/Features/AI/Service/AIProvider.swift \
                           Redcast/Features/AI/Service/AppleIntelligenceProvider.swift
run mcp-oauth-test         Redcast/Platform/ExecutableLocator.swift \
                           Redcast/Platform/ProcessExit.swift \
                           Redcast/Platform/KeychainSecretStore.swift \
                           Redcast/Features/BundleMigration/Model/LegacyBundleMigration.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/AIToolServer.swift \
                           Redcast/Features/AI/Model/AIStreamDecoder.swift \
                           Redcast/Features/ReasoningReplay/Model/*.swift \
                           Redcast/Features/AI/Model/AIProviderFailure.swift \
                           Redcast/Features/AI/Model/AIThinkTagDecoder.swift \
                           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/Agents/Model/ChatToolContent.swift \
                           Redcast/Features/Agents/Model/ChatAccess.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/MCP/Model/*.swift \
                           Redcast/Features/MCP/Service/*.swift
run slow mcp-stdio-test    Redcast/Platform/ExecutableLocator.swift \
                           Redcast/Platform/ProcessExit.swift \
                           Redcast/Platform/KeychainSecretStore.swift \
                           Redcast/Features/BundleMigration/Model/LegacyBundleMigration.swift \
                           Redcast/Features/Settings/AppSettingsKey.swift \
                           Redcast/Features/AI/Model/AIConnection.swift \
                           Redcast/Features/AI/Model/AppleIntelligence.swift \
                           Redcast/Features/AI/Model/AITool.swift \
                           Redcast/Features/AI/Model/AIToolServer.swift \
                           Redcast/Features/AI/Model/AIStreamDecoder.swift \
                           Redcast/Features/ReasoningReplay/Model/*.swift \
                           Redcast/Features/AI/Model/AIProviderFailure.swift \
                           Redcast/Features/AI/Model/AIThinkTagDecoder.swift \
                           Redcast/Features/AI/Model/AIRequest.swift \
                           Redcast/Features/Agents/Model/ChatToolContent.swift \
                           Redcast/Features/Agents/Model/ChatAccess.swift \
                           Redcast/Features/AI/Model/JSONValue.swift \
                           Redcast/Features/MCP/Model/*.swift \
                           Redcast/Features/MCP/Service/*.swift

if [ "$emit_db" -eq 1 ]; then
    printf ']\n' >> "$DB"
    [ -f .compile ] || echo '[]' > .compile
    node -e '
const fs = require("node:fs");
const [comp, db] = process.argv.slice(1);
const existing = JSON.parse(fs.readFileSync(comp, "utf8"));
const harnesses = JSON.parse(fs.readFileSync(db, "utf8"));
const kept = existing.filter((e) => !(e.files || []).some((f) => f.includes("/Tests/")));
fs.writeFileSync(comp, JSON.stringify([...kept, ...harnesses], null, 1));
console.log(harnesses.length + " harness entries indexed into .compile");
' .compile "$DB"
    exit 0
fi

if [ "$ran" -eq 0 ]; then
    echo "No harness named '$only'." >&2
    exit 2
fi

# `sort -s` is stable, so the slow harnesses lead and everything else keeps its declaration order.
JOBS="${REDCAST_TEST_JOBS:-4}"
export REDCAST_TEST_TIMEOUT="${REDCAST_TEST_TIMEOUT:-300}"
started=$SECONDS

# Numbers each result, and names what is still running whenever the output goes quiet.
report() {
    local finished=0 line asked running file
    while :; do
        asked=$SECONDS
        if IFS= read -r -t 15 line; then
            case "$line" in "dispatch "*) return "${line#dispatch }";; esac
            finished=$((finished + 1))
            printf '[%*d/%d] %s\n' "${#ran}" "$finished" "$ran" "$line"
            continue
        fi
        # Bash 3.2 returns the same status for a timeout and EOF; only EOF comes back at once.
        if [ $((SECONDS - asked)) -lt 10 ]; then return 1; fi
        running=""
        for file in "$BIN"/*.running; do
            [ -e "$file" ] && running="$running $(basename "$file" .running)"
        done
        printf '        \033[2mstill running after %ds:%s\033[0m\n' $((SECONDS - started)) "$running"
    done
}

dispatch() {
    [ -s "$1" ] || return 0
    sort -s -k1,1n "$1" | cut -d' ' -f2- | xargs -P "$2" -L1 "$SELF" --exec
}

# Without this the suite reports "all passed" whenever dispatch itself dies and no harness ran.
if ! {
    dispatch "$QUEUE" "$JOBS" && dispatch "$EXCLUSIVE_QUEUE" 1
    echo "dispatch $?"
} | report; then
    echo "harness dispatch failed; no result below can be trusted" >&2
    exit 1
fi
elapsed=$((SECONDS - started))

# A compiler diagnostic is far longer than PIPE_BUF, so the workers log it and it is replayed here.
while read -r _ name _; do
    if [ -f "$BIN/$name.failed" ]; then failed+=("$name"); fi
done < <(cat "$QUEUE" "$EXCLUSIVE_QUEUE")

if [ ${#failed[@]} -gt 0 ]; then
    for name in "${failed[@]}"; do
        printf '\n\033[31m--- %s ---\033[0m\n' "$name"
        cat "$BIN/$name.log"
    done
    printf '\n\033[31mFAILED\033[0m  %d of %d harness(es) failed in %ds: %s\n' \
        "${#failed[@]}" "$ran" "$elapsed" "${failed[*]}" >&2
    exit 1
fi
printf '\n\033[32mPASSED\033[0m  All %d harness(es) passed in %ds.\n' "$ran" "$elapsed"
