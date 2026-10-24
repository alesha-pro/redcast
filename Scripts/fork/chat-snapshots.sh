#!/bin/bash
# Renders AI Chat's window offscreen from fixtures, in light and dark, without launching the app.
# Usage: Scripts/fork/chat-snapshots.sh <output-dir> [built Tinycast Dev.app] [language…]
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1

OUT=${1:?output directory}
APP=${2:-build/DerivedData/Build/Products/Debug/Tinycast Dev.app}
shift $(( $# >= 2 ? 2 : 1 ))
LANGS=("${@:-en}")
WORK="${TMPDIR:-/tmp}/tinycast-chat-snapshots"
BUNDLE="$WORK/ChatSnapshots.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

# The colour sets, brand marks and translations come from a build; the harness has no catalog of its own.
cp "$APP/Contents/Resources/Assets.car" "$BUNDLE/Contents/Resources/"
cp -R "$APP"/Contents/Resources/*.lproj "$BUNDLE/Contents/Resources/"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.tinycast.chat-snapshots</string>
<key>CFBundleExecutable</key><string>chat-snapshots</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

CW=Tinycast/Features/ChatWorkspace
AI=Tinycast/Features/AI
# The transcript and the fork's views; app plumbing they reach (files, tiles, the pasteboard) is
# stood in for at the harness's end.
SOURCES=(
    $AI/Model/*.swift Tinycast/Features/ReasoningReplay/Model/*.swift Tinycast/Features/Agents/Model/*.swift
    Tinycast/Features/WebSearch/Model/*.swift Tinycast/Features/ChatFiles/Model/*.swift
    $AI/UI/ChatTranscriptView.swift $AI/UI/ChatCopyButton.swift $AI/UI/ChatSuggestionChips.swift
    $AI/UI/ChatMarkdownText.swift $AI/UI/ChatMarkdownRenderer.swift $AI/UI/ChatTextHighlight.swift
    $AI/UI/Math*.swift Tinycast/Features/ChatFiles/UI/ChatFileLinker.swift
    Tinycast/Features/Agents/UI/AgentChatHeader.swift Tinycast/Features/Agents/UI/ChatToolContentView.swift
    $AI/Service/AIProvider.swift $AI/Service/ChatHistoryStore.swift
    $AI/UI/AIChatState.swift $AI/UI/AIChatSurfacesState.swift
    Tinycast/DesignSystem/Theme.swift Tinycast/DesignSystem/InterfaceMetrics.swift
    Tinycast/DesignSystem/RaycastPalette.swift Tinycast/DesignSystem/Scrolling/*.swift
    Tinycast/Features/Settings/InterfaceSize.swift Tinycast/Features/Settings/AppSettingsKey.swift
    Tinycast/Platform/Appearance.swift Tinycast/Platform/NotificationToken.swift
    Tinycast/Features/ColorfulIcons/Model/RaycastHue.swift
    $CW/Model/*.swift $CW/Service/*.swift $CW/Settings/ChatWorkspaceSettings.swift
    $CW/UI/ChatWorkspaceHost.swift $CW/UI/ChatWorkspaceCoordinator.swift $CW/UI/ChatSettingsState.swift
    $CW/UI/ChatWorkspaceTheme.swift $CW/UI/ChatWorkspaceSidebar.swift $CW/UI/ChatFolderEditor.swift
    $CW/UI/ChatSettingsSidebar.swift $CW/UI/ChatModelChip.swift $CW/UI/ChatTranscriptColors.swift
    $CW/UI/ChatMessageActions.swift $CW/UI/ChatComposerInk.swift $CW/UI/ChatImageDownsampler.swift
)
swiftc -swift-version 6 -Onone "${SOURCES[@]}" Tests/chat-workspace-snapshots.swift \
    -o "$BUNDLE/Contents/MacOS/chat-snapshots"

mkdir -p "$OUT"
for lang in "${LANGS[@]}"; do
    "$BUNDLE/Contents/MacOS/chat-snapshots" "$OUT" "$WORK/fixtures" -AppleLanguages "($lang)"
done
