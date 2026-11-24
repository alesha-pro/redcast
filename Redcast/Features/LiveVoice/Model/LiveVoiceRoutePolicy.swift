import Foundation

/// Pure routing, consent, endpoint and language rules for Live Voice and its pointer locator.
enum LiveVoiceRoutePolicy {
    static let defaultLocatorModelOpenRouter = "google/gemini-3.1-flash-lite"
    static let defaultLocatorModelGemini = "gemini-3.1-flash-lite"
    static let maxPersonaBytes = 8 * 1_024
    static let maxMemoryBytes = 8 * 1_024
    /// Explicit sentinel stored when the user wants the model to auto-detect every language.
    static let autoLanguage = "auto"

    // MARK: - Live Voice connection

    /// Only providers with a supported WebSocket realtime dialect.
    static func accepts(_ connection: AIConnection) -> Bool {
        provider(for: connection) != nil
    }

    static func provider(for connection: AIConnection) -> LiveVoiceProvider? {
        switch connection.provider {
        case .openAI: .openAI
        case .gemini: .gemini
        case .anthropic, .openRouter, .openAICompatible, .codexPlan: nil
        }
    }

    static func defaultModel(for provider: AIProviderKind) -> String? {
        switch provider {
        case .openAI: OpenAIRealtimeWire.defaultModel
        case .gemini: GeminiLiveWire.defaultModel
        case .anthropic, .openRouter, .openAICompatible, .codexPlan: nil
        }
    }

    static func choices(
        _ connections: [AIConnection], isEnabled: (UUID) -> Bool
    ) -> [AIConnection] {
        connections.filter { accepts($0) && isEnabled($0.id) }
    }

    static func initial(on connection: AIConnection) -> AIModelSelection? {
        guard let model = defaultModel(for: connection.provider) else { return nil }
        return .api(connection: connection.id, model: model, effort: nil)
    }

    /// Consented choice only; never silently substitutes another connection added later.
    static func route(
        _ stored: AIModelSelection?, connections: [AIConnection], isEnabled: (UUID) -> Bool
    ) -> AIModelSelection? {
        guard case .api(let id, let model, _) = stored, !model.isEmpty,
            choices(connections, isEnabled: isEnabled).contains(where: { $0.id == id })
        else { return nil }
        return stored
    }

    /// What enabling proposes: the usable stored choice, else OpenAI, else Gemini.
    static func proposal(
        _ stored: AIModelSelection?, connections: [AIConnection], isEnabled: (UUID) -> Bool
    ) -> AIModelSelection? {
        if let stored = route(stored, connections: connections, isEnabled: isEnabled) {
            return stored
        }
        let offered = choices(connections, isEnabled: isEnabled)
        for kind in [AIProviderKind.openAI, .gemini] {
            if let connection = offered.first(where: { $0.provider == kind }) {
                return initial(on: connection)
            }
        }
        return nil
    }

    /// Maps an HTTP(S) connection base URL to its WebSocket realtime endpoint.
    static func webSocketURL(for provider: LiveVoiceProvider, baseURL: URL, model: String) -> URL {
        let wsScheme = baseURL.scheme?.lowercased() == "http" ? "ws" : "wss"
        switch provider {
        case .openAI:
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
            components.scheme = wsScheme
            let trimmedPath = components.path.hasSuffix("/")
                ? String(components.path.dropLast()) : components.path
            if !trimmedPath.hasSuffix("/realtime") {
                components.path = trimmedPath.isEmpty ? "/v1/realtime" : trimmedPath + "/realtime"
            }
            var items = components.queryItems ?? []
            if !items.contains(where: { $0.name == "model" }) {
                items.append(URLQueryItem(name: "model", value: model))
            }
            components.queryItems = items
            return components.url ?? URL(fileURLWithPath: "/")
        case .gemini:
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
            components.scheme = wsScheme
            components.path =
                "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
            components.queryItems = nil
            return components.url ?? URL(string: GeminiLiveWire.defaultEndpoint) ?? URL(fileURLWithPath: "/")
        }
    }

    // MARK: - Pointer locator connection

    /// Any OpenAI-compatible chat endpoint (OpenRouter, Gemini, OpenAI, custom) except Codex plan.
    static func acceptsLocator(_ connection: AIConnection) -> Bool {
        connection.provider.apiShape == .openAICompatible && connection.provider != .codexPlan
    }

    static func locatorDefaultModel(for provider: AIProviderKind) -> String? {
        switch provider {
        case .openRouter: defaultLocatorModelOpenRouter
        case .gemini: defaultLocatorModelGemini
        case .openAI, .anthropic, .openAICompatible, .codexPlan: nil
        }
    }

    static func locatorChoices(
        _ connections: [AIConnection], isEnabled: (UUID) -> Bool
    ) -> [AIConnection] {
        connections.filter { acceptsLocator($0) && isEnabled($0.id) && locatorInitial(on: $0) != nil }
    }

    static func locatorInitial(on connection: AIConnection) -> AIModelSelection? {
        if let preset = locatorDefaultModel(for: connection.provider) {
            return .api(connection: connection.id, model: preset, effort: nil)
        }
        return connection.models.first.map { .api(connection: connection.id, model: $0, effort: nil) }
    }

    /// Consented locator choice only; nil turns `point_at` off rather than guessing a route.
    static func locatorRoute(
        _ stored: AIModelSelection?, connections: [AIConnection], isEnabled: (UUID) -> Bool
    ) -> AIModelSelection? {
        guard case .api(let id, let model, _) = stored, !model.isEmpty,
            locatorChoices(connections, isEnabled: isEnabled).contains(where: { $0.id == id })
        else { return nil }
        return stored
    }

    /// OpenRouter or Gemini grounding preset when first enabling Live Voice; nil if neither exists.
    static func locatorProposal(
        _ stored: AIModelSelection?, connections: [AIConnection], isEnabled: (UUID) -> Bool
    ) -> AIModelSelection? {
        if let stored = locatorRoute(stored, connections: connections, isEnabled: isEnabled) {
            return stored
        }
        let offered = locatorChoices(connections, isEnabled: isEnabled)
        for kind in [AIProviderKind.openRouter, .gemini] {
            if let connection = offered.first(where: { $0.provider == kind }) {
                return locatorInitial(on: connection)
            }
        }
        return nil
    }

    // MARK: - Language & prompt bounds

    static func resolvedLanguage(
        setting: String?, preferredLanguages: [String]
    ) -> (code: String?, englishName: String) {
        let trimmed = setting?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed == autoLanguage { return (nil, "") }
        let identifier = trimmed.isEmpty ? (preferredLanguages.first ?? "") : trimmed
        guard !identifier.isEmpty,
            let code = Locale.Language(identifier: identifier).languageCode?.identifier,
            !code.isEmpty
        else { return (nil, "") }
        let english = Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? ""
        return (code, english)
    }

    static func boundedText(_ text: String?, maxBytes: Int) -> String {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.utf8.count > maxBytes else { return trimmed }
        var end = trimmed.startIndex
        var used = 0
        for index in trimmed.indices {
            let size = trimmed[index].utf8.count
            if used + size > maxBytes { break }
            used += size
            end = trimmed.index(after: index)
        }
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "\n…"
    }
}
