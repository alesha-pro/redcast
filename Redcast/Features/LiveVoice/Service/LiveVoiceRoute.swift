import Foundation

/// Resolves a consented Live Voice or pointer-locator selection into its wire or HTTP client.
@MainActor
enum LiveVoiceRoute {
    static func wire(
        for selection: AIModelSelection, effort: LiveVoiceEffort, settings: AISettingsStore,
        keys: KeychainSecretStore = .aiAPIKeys, headers: KeychainSecretStore = .aiRequestHeaders
    ) throws -> (provider: LiveVoiceProvider, wire: any LiveVoiceWire) {
        let resolved = try credentials(
            for: selection, settings: settings, accepts: LiveVoiceRoutePolicy.accepts,
            keys: keys, headers: headers)
        guard let provider = LiveVoiceRoutePolicy.provider(for: resolved.connection) else {
            throw AIProviderError.unavailable(
                String(localized: "Choose an OpenAI or Google Gemini connection in Settings."))
        }
        let endpoint = LiveVoiceRoutePolicy.webSocketURL(
            for: provider, baseURL: resolved.baseURL, model: selection.model)
        let wire: any LiveVoiceWire =
            switch provider {
            case .openAI:
                OpenAIRealtimeWire(
                    key: resolved.key, model: selection.model, effort: effort.rawValue,
                    endpoint: endpoint, headers: resolved.headers)
            case .gemini:
                GeminiLiveWire(
                    key: resolved.key, model: selection.model, endpoint: endpoint,
                    headers: resolved.headers)
            }
        return (provider, wire)
    }

    static func locator(
        for selection: AIModelSelection, settings: AISettingsStore,
        keys: KeychainSecretStore = .aiAPIKeys, headers: KeychainSecretStore = .aiRequestHeaders
    ) throws -> LiveVoicePointLocator {
        let resolved = try credentials(
            for: selection, settings: settings, accepts: LiveVoiceRoutePolicy.acceptsLocator,
            keys: keys, headers: headers)
        let config = AIHTTPConfiguration(
            provider: resolved.connection.provider, baseURL: resolved.baseURL,
            model: selection.model, headers: resolved.headers)
        return LiveVoicePointLocator(
            key: resolved.key, model: selection.model, endpoint: config.endpointURL,
            headers: resolved.headers)
    }

    private static func credentials(
        for selection: AIModelSelection, settings: AISettingsStore,
        accepts: (AIConnection) -> Bool, keys: KeychainSecretStore, headers: KeychainSecretStore
    ) throws -> (connection: AIConnection, baseURL: URL, key: String, headers: [String: String]) {
        guard case .api(let id, _, _) = selection,
            let connection = settings.connection(id: id), accepts(connection)
        else {
            throw AIProviderError.unavailable(String(localized: "Choose an API connection in Settings."))
        }
        guard settings.isRouteEnabled(.api(id)) else {
            throw AIProviderError.unavailable(
                String(localized: "\(connection.title) is disabled in AI Settings."))
        }
        let baseURL: URL
        do {
            baseURL = try AIEndpointPolicy.validate(connection.baseURL)
        } catch let error as AIEndpointPolicy.ValidationError {
            throw AIProviderError.unavailable(error.localizedDescription)
        }
        let key: String
        let values: [String: String]
        do {
            key = try keys.secret(for: id) ?? ""
        } catch {
            throw AIProviderError.unavailable(
                String(localized: "The API key could not be read from Keychain."))
        }
        do {
            values = try headers.values(for: id)
        } catch {
            throw AIProviderError.unavailable(
                String(localized: "The request headers could not be read from Keychain."))
        }
        guard AIEndpointPolicy.isLoopback(connection.baseURL) || !key.isEmpty || !values.isEmpty else {
            throw AIProviderError.unavailable(String(localized: "Add an API key in Settings."))
        }
        return (connection, baseURL, key, values)
    }
}
