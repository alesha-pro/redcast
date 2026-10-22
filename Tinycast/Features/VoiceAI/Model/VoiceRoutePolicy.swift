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

    /// The order a route is looked for when nothing is chosen: the two whose defaults are known.
    private static let preferredProviders: [AIProviderKind] = [.openRouter, .gemini]
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

    /// Only bodies Tinycast writes with input_audio: every OpenAI-compatible shape, never Anthropic.
    static func accepts(_ connection: AIConnection) -> Bool {
        connection.provider.apiShape == .openAICompatible
    }

    /// A usable stored choice, else the OpenRouter then Gemini preset, else a listed model.
    static func resolve(
        _ stored: AIModelSelection?, use: VoiceUse, connections: [AIConnection],
        isEnabled: (UUID) -> Bool
    ) -> AIModelSelection? {
        let eligible = connections.filter { accepts($0) && isEnabled($0.id) }
        if case .api(let id, let model, _) = stored, !model.isEmpty,
            eligible.contains(where: { $0.id == id })
        {
            return stored
        }
        for provider in preferredProviders {
            guard let connection = eligible.first(where: { $0.provider == provider }),
                let preset = defaults(for: use, provider: provider)
            else { continue }
            return .api(connection: connection.id, model: preset.model, effort: preset.effort)
        }
        guard let connection = eligible.first(where: { !$0.models.isEmpty }),
            let model = connection.models.first
        else { return nil }
        return .api(connection: connection.id, model: model, effort: nil)
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

    /// A model the connection's own catalog marked text-only is sent no picture.
    static func takesImages(_ connection: AIConnection, model: String) -> Bool {
        !connection.models.contains(model) || connection.capabilities(for: model).images
    }
}
