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
    static func request(prompt: String) -> AIRequest {
        AIRequest(instructions: nil, messages: [AIMessage(role: .user, text: prompt)])
    }

    /// A pick whose API connection or model was deleted; a route merely switched off is not.
    static func isDangling(_ selection: AIModelSelection, connections: [AIConnection]) -> Bool {
        guard case .api(let id, let model, _) = selection else { return false }
        return !connections.contains { $0.id == id && $0.models.contains(model) }
    }
}
