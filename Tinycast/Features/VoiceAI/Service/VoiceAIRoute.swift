import Foundation

/// AIProviderFactory without its effort filter: a voice model need not be in the connection's list.
@MainActor
enum VoiceAIRoute {
    static func provider(
        for selection: AIModelSelection, settings: AISettingsStore,
        keys: KeychainSecretStore = .aiAPIKeys, headers: KeychainSecretStore = .aiRequestHeaders
    ) throws -> any AIProvider {
        let route = try credentials(for: selection, settings: settings, keys: keys, headers: headers)
        let provider = HTTPAIProvider(
            configuration: AIHTTPConfiguration(
                provider: route.connection.provider, baseURL: route.baseURL, model: selection.model,
                effort: selection.effort,
                disablesThinking: selection.effort == AIConnection.ReasoningOptions.noEffort
                    && route.connection.takesThinkingField,
                headers: route.headers),
            apiKey: route.key)
        // Dictation and Ask by Voice both come through here, and neither reply is a chat's.
        return UsageRecordingProvider.wrapping(provider, for: selection, as: .voice)
    }

    /// The same checks for a model that only transcribes, which takes no chat request.
    static func transcriber(
        for selection: AIModelSelection, settings: AISettingsStore,
        keys: KeychainSecretStore = .aiAPIKeys, headers: KeychainSecretStore = .aiRequestHeaders
    ) throws -> VoiceTranscriptionClient {
        let route = try credentials(for: selection, settings: settings, keys: keys, headers: headers)
        return VoiceTranscriptionClient(
            baseURL: route.baseURL, apiKey: route.key, headers: route.headers, selection: selection)
    }

    private static func credentials(
        for selection: AIModelSelection, settings: AISettingsStore, keys: KeychainSecretStore,
        headers: KeychainSecretStore
    ) throws -> (connection: AIConnection, baseURL: URL, key: String, headers: [String: String]) {
        guard case .api(let id, _, _) = selection,
            let connection = settings.connection(id: id), VoiceRoutePolicy.accepts(connection)
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
