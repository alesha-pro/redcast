import Foundation

/// What an `AI.ask` may do; checked again on every read, so a switch turned off ends a stream.
enum ExtensionAIAccess: Equatable, Sendable {
    case allowed
    case ask
    case refused(ExtensionAIRefusal)
}

/// Pure decisions for extension AI: gates, prompt bounds, the request, a dangling route.
enum ExtensionAIPolicy {
    static let maxPromptBytes = 256 * 1_024

    static func access(
        featureOn: Bool, aiOn: Bool, actingForUser: Bool, grant: Bool?
    ) -> ExtensionAIAccess {
        guard featureOn else { return .refused(.featureOff) }
        guard aiOn else { return .refused(.aiOff) }
        guard actingForUser else { return .refused(.unattended) }
        switch grant {
        case nil: return .ask
        case true?: return .allowed
        case false?: return .refused(.denied)
        }
    }

    /// Rejects an empty (whitespace-only) or oversized prompt; returns it unchanged otherwise.
    static func prompt(from raw: String) throws(ExtensionAIRefusal) -> String {
        guard !raw.allSatisfy(\.isWhitespace) else { throw .emptyPrompt }
        let bytes = raw.utf8.count
        guard bytes <= maxPromptBytes else {
            throw .promptTooLong(kilobytes: (bytes + 1_023) / 1_024)
        }
        return raw
    }

    /// The prompt is the whole turn: no preamble, tools, history or web search.
    static func request(prompt: String, temperature: Double? = nil) -> AIRequest {
        AIRequest(
            instructions: nil, messages: [AIMessage(role: .user, text: prompt)], temperature: temperature)
    }

    /// Raycast's named levels on OpenAI's 0–2 scale, where 1 is every route's usual default.
    static let creativityLevels: [String: Double] = [
        "none": 0, "low": 0.4, "medium": 0.7, "high": 1, "maximum": 1.5
    ]

    /// A level or a number clamped to 0–2, as Raycast documents; anything else keeps the default.
    static func temperature(creativity: RenderValue?, brand: AIBrand?) -> Double? {
        // Gemini 3 loops below its default temperature, so every Gemini model keeps its own.
        guard brand != .gemini else { return nil }
        switch creativity {
        case .string(let level)?: return creativityLevels[level.lowercased()]
        case .number(let value)? where value.isFinite: return min(max(value, 0), 2)
        default: return nil
        }
    }

    /// OpenAI's reasoning models take only their default; such a refusal names the parameter.
    static func withoutTemperature(_ request: AIRequest, after error: any Error) -> AIRequest? {
        guard request.temperature != nil,
            error.localizedDescription.localizedCaseInsensitiveContains("temperature")
        else { return nil }
        return AIRequest(
            instructions: request.instructions, messages: request.messages,
            maxOutputTokens: request.maxOutputTokens, webSearch: request.webSearch,
            tools: request.tools, conversationID: request.conversationID)
    }

    /// A pick whose API connection or model was deleted; a route merely switched off is not.
    static func isDangling(_ selection: AIModelSelection, connections: [AIConnection]) -> Bool {
        guard case .api(let id, let model, _) = selection else { return false }
        return !connections.contains { $0.id == id && $0.models.contains(model) }
    }
}
