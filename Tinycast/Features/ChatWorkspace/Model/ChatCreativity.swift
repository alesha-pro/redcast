import Foundation

/// Fork: Raycast's Creativity for one chat; unset leaves the model's own temperature.
enum ChatCreativity: String, CaseIterable, Identifiable, Sendable {
    case none, low, medium, high, maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "creativity-none", defaultValue: "None")
        case .low: String(localized: "creativity-low", defaultValue: "Low")
        case .medium: String(localized: "creativity-medium", defaultValue: "Medium")
        case .high: String(localized: "creativity-high", defaultValue: "High")
        case .maximum: String(localized: "creativity-maximum", defaultValue: "Maximum")
        }
    }

    /// Raycast's levels on OpenAI's 0–2 scale, the same table extensions' `creativity` uses.
    var temperature: Double {
        switch self {
        case .none: 0
        case .low: 0.4
        case .medium: 0.7
        case .high: 1
        case .maximum: 1.5
        }
    }
}

extension AIRequest {
    /// The same turn at another temperature; every other field, the loop's included, carries over.
    func withTemperature(_ temperature: Double?) -> AIRequest {
        AIRequest(
            instructions: instructions, messages: messages, maxOutputTokens: maxOutputTokens,
            webSearch: webSearch, tools: tools, conversationID: conversationID,
            temperature: temperature, outputCap: outputCap, forbidsCalls: forbidsCalls)
    }
}
