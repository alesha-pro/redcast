#!/bin/bash
# Renders AI Chat's window offscreen from fixtures, in light and dark, without launching the app.
# Usage: Scripts/chat-snapshots.sh <output-dir> [built Redcast Dev.app] [language…]
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT=${1:?output directory}
APP=${2:-build/DerivedData/Build/Products/Debug/Redcast Dev.app}
shift $(( $# >= 2 ? 2 : 1 ))
LANGS=("${@:-en}")
WORK="${TMPDIR:-/tmp}/redcast-chat-snapshots"
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
<key>CFBundleIdentifier</key><string>io.redcast.chat-snapshots</string>
<key>CFBundleExecutable</key><string>chat-snapshots</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

CW=Redcast/Features/ChatWorkspace
AI=Redcast/Features/AI
# The transcript and the fork's views; app plumbing they reach (files, tiles, the pasteboard) is
# stood in for at the harness's end.
SOURCES=(
    $AI/Model/*.swift Redcast/Features/ReasoningReplay/Model/*.swift Redcast/Features/Agents/Model/*.swift
    Redcast/Features/WebSearch/Model/*.swift Redcast/Features/ChatFiles/Model/*.swift
    $AI/UI/ChatTranscriptView.swift $AI/UI/ChatCopyButton.swift $AI/UI/ChatSuggestionChips.swift
    $AI/UI/ChatMarkdownText.swift $AI/UI/ChatMarkdownRenderer.swift $AI/UI/ChatTextHighlight.swift
    $AI/UI/Math*.swift Redcast/Features/ChatFiles/UI/ChatFileLinker.swift
    Redcast/Features/Agents/UI/AgentChatHeader.swift Redcast/Features/Agents/UI/ChatToolContentView.swift
    $AI/Service/AIProvider.swift $AI/Service/ChatHistoryStore.swift
    $AI/UI/AIChatState.swift $AI/UI/AIChatSurfacesState.swift
    Redcast/DesignSystem/Theme.swift Redcast/DesignSystem/InterfaceMetrics.swift
    Redcast/DesignSystem/RaycastPalette.swift Redcast/DesignSystem/Scrolling/*.swift
    Redcast/Features/Settings/InterfaceSize.swift Redcast/Features/Settings/AppSettingsKey.swift
    Redcast/Platform/Appearance.swift Redcast/Platform/NotificationToken.swift
    Redcast/Features/ColorfulIcons/Model/RaycastHue.swift
    $CW/Model/*.swift $CW/Service/*.swift $CW/Settings/ChatWorkspaceSettings.swift
    $CW/UI/ChatWorkspaceHost.swift $CW/UI/ChatWorkspaceCoordinator.swift $CW/UI/ChatSettingsState.swift
    $CW/UI/ChatWorkspaceCoordinator+Selection.swift
    $CW/UI/ChatWorkspaceTheme.swift $CW/UI/ChatWorkspaceSidebar.swift $CW/UI/ChatFolderEditor.swift
    $CW/UI/ChatSettingsSidebar.swift $CW/UI/ChatModelChip.swift $CW/UI/ChatTranscriptColors.swift
    $CW/UI/ChatMessageActions.swift $CW/UI/ChatComposerInk.swift $CW/UI/ChatImageDownsampler.swift
    $CW/UI/ChatToolTip.swift
)
swiftc -swift-version 6 -Onone "${SOURCES[@]}" Tests/chat-workspace-snapshots.swift \
    -o "$BUNDLE/Contents/MacOS/chat-snapshots"

mkdir -p "$OUT"
for lang in "${LANGS[@]}"; do
    "$BUNDLE/Contents/MacOS/chat-snapshots" "$OUT" "$WORK/fixtures" -AppleLanguages "($lang)"
done
