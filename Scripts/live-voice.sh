#!/bin/bash
# A live Live Voice session from the terminal: microphone, speaker, screen and pointer, no app.
# Usage: OPENAI_API_KEY=… Scripts/live-voice.sh [--provider openai|gemini] [--screen turn|tool|off] …
# Not in run-tests: it talks to a paid API. See docs/features/live-voice.md.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${TMPDIR:-/tmp}/redcast-harness"
mkdir -p "$BIN"
swiftc -swift-version 6 -O \
    Redcast/Platform/Appearance.swift Redcast/DesignSystem/Theme.swift \
    Redcast/DesignSystem/Interaction/Motion.swift \
    Redcast/Features/AI/Model/AITool.swift Redcast/Features/AI/Model/JSONValue.swift \
    Redcast/Features/AI/Model/AIConnection.swift Redcast/Features/AI/Model/AppleIntelligence.swift \
    Redcast/Features/LiveVoice/Model/*.swift \
    Redcast/Features/LiveVoice/Service/LiveVoiceAudio.swift \
    Redcast/Features/LiveVoice/Service/LiveVoiceConnection.swift \
    Redcast/Features/LiveVoice/Service/LiveVoicePointLocator.swift \
    Redcast/Features/LiveVoice/Service/LiveVoiceScreenTools.swift \
    Redcast/Features/LiveVoice/Service/LiveVoiceScreenshotter.swift \
    Redcast/Features/LiveVoice/Service/LiveVoiceSession.swift \
    Redcast/Features/LiveVoice/UI/LiveVoicePointerController.swift Tests/live-voice-live.swift \
    -o "$BIN/live-voice"
exec "$BIN/live-voice" "$@"
