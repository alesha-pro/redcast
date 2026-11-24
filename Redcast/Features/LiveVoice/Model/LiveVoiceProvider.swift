import Foundation

/// Who answers a live session. A new provider is one more wire and one more case here.
enum LiveVoiceProvider: String, CaseIterable, Sendable {
    case openAI = "openai"
    case gemini

    var defaultModel: String {
        switch self {
        case .openAI: OpenAIRealtimeWire.defaultModel
        case .gemini: GeminiLiveWire.defaultModel
        }
    }

    var defaultVoice: String {
        switch self {
        case .openAI: OpenAIRealtimeWire.defaultVoice
        case .gemini: GeminiLiveWire.defaultVoice
        }
    }

    /// Built-in voices ordered with the strongest measured pronunciation first.
    var voices: [String] {
        switch self {
        case .openAI:
            ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
        case .gemini:
            ["Puck", "Charon", "Kore", "Fenrir", "Aoede", "Leda", "Orus", "Zephyr"]
        }
    }

    /// OpenAI emits `speech_started` before each spoken turn; Gemini usually does not.
    var reportsSpeechStart: Bool { self == .openAI }

    /// OpenAI drops sessions at 60 min; proactively reconnect at 55 min. Gemini sends `goAway`.
    var maxConnectionLifetime: Duration? {
        switch self {
        case .openAI: .seconds(55 * 60)
        case .gemini: nil
        }
    }

    /// The environment variable a hand-run stand reads the key from.
    var keyVariable: String {
        switch self {
        case .openAI: "OPENAI_API_KEY"
        case .gemini: "GEMINI_API_KEY"
        }
    }

    func wire(
        key: String, model: String? = nil, endpoint: URL? = nil, headers: [String: String] = [:]
    ) -> any LiveVoiceWire {
        switch self {
        case .openAI:
            OpenAIRealtimeWire(
                key: key, model: model ?? defaultModel, endpoint: endpoint, headers: headers)
        case .gemini:
            GeminiLiveWire(
                key: key, model: model ?? defaultModel, endpoint: endpoint, headers: headers)
        }
    }
}

/// How Live Voice sees the display under the cursor once the user consents for the session.
enum LiveVoiceScreenMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case everyTurn
    case onRequest
    case off

    var id: String { rawValue }
}

/// How Live Voice stops the assistant from hearing its own speech through the microphone.
enum LiveVoiceAudioMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case headphones
    case mutedWhileSpeaking

    var id: String { rawValue }
}

/// OpenAI Realtime's reasoning effort levels; `minimal` answers fastest.
enum LiveVoiceEffort: String, CaseIterable, Codable, Identifiable, Sendable {
    case minimal
    case low
    case medium
    case high

    var id: String { rawValue }
}
