import Foundation
import Observation

/// The engine list, persisted as one JSON value; keys stay in the Keychain and are read on demand.
@MainActor
@Observable
final class WebSearchSettingsStore {
    private let defaults: UserDefaults
    private let keychain: KeychainSecretStore

    private(set) var configuration: WebSearchConfiguration {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard, keychain: KeychainSecretStore = .webSearchKeys) {
        self.defaults = defaults
        self.keychain = keychain
        configuration =
            defaults.data(forKey: AppSettingsKey.aiWebSearchEngines.rawValue)
            .flatMap { try? JSONDecoder().decode(WebSearchConfiguration.self, from: $0) }
            ?? .standard
    }

    /// Brand names joined by arrows read the same in every language.
    var summary: String {
        let chain = configuration.chain
        return chain.isEmpty
            ? String(localized: "None switched on") : chain.map(\.title).joined(separator: " → ")
    }

    func save(_ configuration: WebSearchConfiguration) {
        guard configuration != self.configuration else { return }
        self.configuration = configuration
    }

    func keys() throws -> [String: String] {
        try keychain.values(for: WebSearchSource.keychainAccount)
    }

    /// Blank values are dropped; with none left the item itself goes.
    func setKeys(_ keys: [String: String]) throws {
        try keychain.setValues(keys.filter { !$0.value.isEmpty }, for: WebSearchSource.keychainAccount)
    }

    /// A value for one turn: the chain and address now, the keys only if a keyed engine is reached.
    func runner(canFetch: Bool) -> WebSearchRunner {
        let keychain = keychain
        return WebSearchRunner(
            chain: configuration.chain,
            searxng: try? WebSearchEndpoint.searxngURL(configuration.searxngAddress).get(),
            canFetch: canFetch,
            keys: { (try? keychain.values(for: WebSearchSource.keychainAccount)) ?? [:] })
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: AppSettingsKey.aiWebSearchEngines.rawValue)
    }
}
