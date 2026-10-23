import Foundation

enum VoiceUse: Sendable {
    case dictation
    case ask
}

/// Which connection and model hear a recording, decided from settings alone.
enum VoiceRoutePolicy {
    struct Default: Equatable, Sendable {
        let model: String
        let effort: String?
    }

    /// OpenAI's listed chat models take no input_audio, so it is chosen by hand, never proposed.
    private static let proposedProviders: [AIProviderKind] = [.openRouter, .gemini, .openAICompatible]
    /// Gemini 3 cannot switch reasoning off, so `none` only ranks above the costlier levels.
    private static let effortsFastestFirst = ["minimal", "low", "none", "medium"]

    /// From the live OpenRouter catalog, 2026-10-22; re-check when Google ships a new Flash.
    static func defaults(for use: VoiceUse, provider: AIProviderKind) -> Default? {
        let model: String
        let effort: String
        switch use {
        case .dictation: (model, effort) = ("gemini-3.1-flash-lite", "minimal")
        case .ask: (model, effort) = ("gemini-3.8-flash", "low")
        }
        switch provider {
        case .openRouter: return Default(model: "google/" + model, effort: effort)
        case .gemini: return Default(model: model, effort: effort)
        case .openAI, .anthropic, .openAICompatible: return nil
        }
    }

    /// Only a body Tinycast writes with input_audio: any OpenAI-compatible shape, never Anthropic.
    static func accepts(_ connection: AIConnection) -> Bool {
        connection.provider.apiShape == .openAICompatible
    }

    /// Where a recording goes: only the consented choice, never a substitute for a missing one.
    static func route(
        _ stored: AIModelSelection?, use: VoiceUse, connections: [AIConnection],
        isEnabled: (UUID) -> Bool
    ) -> AIModelSelection? {
        guard case .api(let id, let model, _) = stored, !model.isEmpty,
            choices(connections, use: use, isEnabled: isEnabled).contains(where: { $0.id == id })
        else { return nil }
        return stored
    }

    /// What a consent dialog names: the usable stored choice, else the first proposed preset.
    static func proposal(
        _ stored: AIModelSelection?, use: VoiceUse, connections: [AIConnection],
        isEnabled: (UUID) -> Bool
    ) -> AIModelSelection? {
        if let stored = route(stored, use: use, connections: connections, isEnabled: isEnabled) {
            return stored
        }
        let offered = choices(connections, use: use, isEnabled: isEnabled)
        for provider in proposedProviders {
            if let connection = offered.first(where: { $0.provider == provider }) {
                return initial(on: connection, use: use)
            }
        }
        return nil
    }

    /// The connections a voice route may use: enabled, audio-capable and with a model to name.
    static func choices(
        _ connections: [AIConnection], use: VoiceUse, isEnabled: (UUID) -> Bool
    ) -> [AIConnection] {
        connections.filter { accepts($0) && isEnabled($0.id) && initial(on: $0, use: use) != nil }
    }

    /// A connection's starting model: the preset where one is known, else the first it lists.
    static func initial(on connection: AIConnection, use: VoiceUse) -> AIModelSelection? {
        if let preset = defaults(for: use, provider: connection.provider) {
            return .api(connection: connection.id, model: preset.model, effort: preset.effort)
        }
        return connection.models.first.map { .api(connection: connection.id, model: $0, effort: nil) }
    }

    /// The cheapest level the catalog lists, any real level before "none"; nil keeps the default.
    static func fastestEffort(_ supported: [String]?) -> String? {
        guard let supported else { return nil }
        return effortsFastestFirst.first(where: supported.contains)
    }

    /// A typed model keeps the preset's effort only when it is the preset's own model.
    static func effort(forTyped model: String, use: VoiceUse, provider: AIProviderKind) -> String? {
        guard let preset = defaults(for: use, provider: provider), preset.model == model else { return nil }
        return preset.effort
    }

    /// OpenRouter says which models hear audio; a catalog that doesn't say keeps every model.
    static func audioModels(_ models: [AIModelDiscovery.Model]) -> [AIModelDiscovery.Model] {
        models.filter { $0.inputModalities?.contains("audio") ?? true }
    }

    /// Gemini rewrites speech as it hears it; any other model transcribes, then rewrites as text.
    static func rewritesWhileTranscribing(_ model: String) -> Bool {
        model.lowercased().contains("gemini")
    }

    /// Low enough to keep a transcript literal; Gemini keeps its own, as below it Gemini 3 loops.
    static let dictationTemperature = 0.2

    /// A dictation saved with no effort, on OpenRouter's Gemini Flash, thinks as little as it can.
    static func dictation(_ selection: AIModelSelection, connections: [AIConnection]) -> AIModelSelection {
        guard case .api(let id, let model, .none) = selection,
            provider(of: selection, in: connections) == .openRouter,
            rewritesWhileTranscribing(model), model.lowercased().contains("flash")
        else { return selection }
        return .api(connection: id, model: model, effort: "minimal")
    }

    /// Gemini as built; elsewhere one user turn, since a chat template may insist roles alternate.
    static func fitted(
        _ request: AIRequest, for selection: AIModelSelection, connections: [AIConnection]
    ) -> AIRequest {
        let provider = provider(of: selection, in: connections)
        guard provider != .gemini, !rewritesWhileTranscribing(selection.model) else { return request }
        var messages = request.messages
        if messages.count > 1, messages.allSatisfy({ $0.role == .user }) {
            let text = messages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            messages = [
                AIMessage(
                    role: .user, text: text, images: messages.flatMap(\.images),
                    audio: messages.flatMap(\.audio))
            ]
        }
        let takesTemperature = provider == .openRouter || provider == .openAICompatible
        return AIRequest(
            instructions: request.instructions, messages: messages,
            maxOutputTokens: request.maxOutputTokens,
            temperature: takesTemperature ? dictationTemperature : request.temperature)
    }

    private static func provider(
        of selection: AIModelSelection, in connections: [AIConnection]
    ) -> AIProviderKind? {
        guard case .api(let id, _, _) = selection else { return nil }
        return connections.first { $0.id == id }?.provider
    }

    /// A model the connection's own catalog marked text-only is sent no picture.
    static func takesImages(_ connection: AIConnection, model: String) -> Bool {
        !connection.models.contains(model) || connection.capabilities(for: model).images
    }
}
