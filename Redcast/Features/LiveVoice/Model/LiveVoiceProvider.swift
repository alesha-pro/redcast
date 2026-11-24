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

    /// The environment variable a hand-run stand reads the key from.
    var keyVariable: String {
        switch self {
        case .openAI: "OPENAI_API_KEY"
        case .gemini: "GEMINI_API_KEY"
        }
    }

    func wire(key: String, model: String? = nil) -> any LiveVoiceWire {
        switch self {
        case .openAI: OpenAIRealtimeWire(key: key, model: model ?? defaultModel)
        case .gemini: GeminiLiveWire(key: key, model: model ?? defaultModel)
        }
    }
}
