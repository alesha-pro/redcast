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
SOURCES=(
    $CW/Model/*.swift $CW/Service/*.swift $CW/Settings/ChatWorkspaceSettings.swift
    $CW/UI/ChatWorkspaceHost.swift $CW/UI/ChatWorkspaceCoordinator.swift $CW/UI/ChatWorkspaceTheme.swift
    $CW/UI/ChatWorkspaceSidebar.swift $CW/UI/ChatFolderEditor.swift
    Tinycast/Features/ColorfulIcons/Model/RaycastHue.swift Tinycast/DesignSystem/RaycastPalette.swift
    Tinycast/DesignSystem/Theme.swift Tinycast/Platform/Appearance.swift
    Tinycast/Features/Settings/AppSettingsKey.swift
    $AI/Model/AIRequest.swift Tinycast/Features/Agents/Model/ChatToolContent.swift
    $AI/Model/AIConnection.swift $AI/Model/AIConversationOpenPolicy.swift $AI/Model/AppleIntelligence.swift
    $AI/Model/AIAttachmentPolicy.swift $AI/Model/AIRetention.swift $AI/Model/AITool.swift
    $AI/Model/JSONValue.swift $AI/Model/ChatMessage.swift $AI/Model/ChatSession.swift
    $AI/Model/ChatChoices.swift $AI/Model/ChatToolScope.swift $AI/Service/AIProvider.swift
    $AI/Service/ChatHistoryStore.swift $AI/UI/AIChatState.swift $AI/UI/AIChatSurfacesState.swift
)
swiftc -swift-version 6 -Onone "${SOURCES[@]}" Tests/chat-workspace-snapshots.swift \
    -o "$BUNDLE/Contents/MacOS/chat-snapshots"

mkdir -p "$OUT"
for lang in "${LANGS[@]}"; do
    "$BUNDLE/Contents/MacOS/chat-snapshots" "$OUT" "$WORK/fixtures" -AppleLanguages "($lang)"
done
