import Foundation
import Security

struct KeychainSecretStore: Sendable {
    enum StoreError: Error {
        case invalidEncoding
        case keychain(OSStatus)
    }

    private let service: String
    // Fork: the item's service under the fork's old bundle id; read once, then moved (bundle-migration.md).
    private let legacyService: String?

    /// Every scope the app stores under, named here so the whole keychain surface is one list.
    static let aiAPIKeys = KeychainSecretStore(scope: "ai-api-keys")
    static let aiRequestHeaders = KeychainSecretStore(scope: "ai-request-headers")
    static let mcpSecrets = KeychainSecretStore(scope: "mcp-secrets")
    static let installedAIEnvironment = KeychainSecretStore(scope: "installed-ai-environment")
    static let webSearchKeys = KeychainSecretStore(scope: "web-search-keys")
    // Fork: sent only to OpenRouter's /credits, by Check Balance in Settings → AI → Usage.
    static let openRouterManagementKeys = KeychainSecretStore(scope: "openrouter-management-keys")
    // Fork: one Sign in with ChatGPT record per Codex (ChatGPT) connection; see codex-provider.md.
    static let codexPlanCredentials = KeychainSecretStore(scope: "codex-plan-credentials")

    init(scope: String, bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        service = "\(bundleIdentifier ?? "com.tinycast.app").\(scope)"
        legacyService = LegacyBundleMigration.legacyService(scope: scope, bundleID: bundleIdentifier)  // Fork
    }

    func secret(for account: UUID) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query(for: account, returningData: true) as CFDictionary, &result)
        if status == errSecItemNotFound { return try movedLegacySecret(for: account) }  // Fork
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidEncoding
        }
        return secret
    }

    /// Presence check without `kSecReturn*`, so no secret bytes are materialized.
    func hasSecret(for account: UUID) throws -> Bool {
        let status = SecItemCopyMatching(
            query(for: account, returningData: false) as CFDictionary, nil)
        if status == errSecItemNotFound { return legacyExists(for: account) }  // Fork
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        return true
    }

    func setSecret(_ secret: String, for account: UUID) throws {
        guard let data = secret.data(using: .utf8) else { throw StoreError.invalidEncoding }
        let lookup = query(for: account, returningData: false)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addition = lookup
            addition[kSecValueData as String] = data
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw StoreError.keychain(status)
        }
    }

    func removeSecret(for account: UUID) throws {
        if let legacyService {  // Fork: a removed key never comes back from the old id
            _ = SecItemDelete(query(for: account, returningData: false, service: legacyService) as CFDictionary)
        }
        let status = SecItemDelete(query(for: account, returningData: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    /// One JSON item per account; a failed read throws, a garbled item reads as none.
    func values(for account: UUID) throws -> [String: String] {
        guard let stored = try secret(for: account) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: Data(stored.utf8))) ?? [:]
    }

    func setValues(_ values: [String: String], for account: UUID) throws {
        guard !values.isEmpty else { return try removeSecret(for: account) }
        guard let encoded = String(bytes: try JSONEncoder().encode(values), encoding: .utf8) else {
            throw StoreError.invalidEncoding
        }
        try setSecret(encoded, for: account)
    }

    // Fork: the old id's item, copied under the new service on first read; macOS may ask once to allow it.
    private func movedLegacySecret(for account: UUID) throws -> String? {
        guard let legacyService else { return nil }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query(for: account, returningData: true, service: legacyService) as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8)
        else { return nil }
        try? setSecret(secret, for: account)
        return secret
    }

    private func legacyExists(for account: UUID) -> Bool {
        guard let legacyService else { return false }
        return SecItemCopyMatching(
            query(for: account, returningData: false, service: legacyService) as CFDictionary, nil) == errSecSuccess
    }

    private func query(for account: UUID, returningData: Bool, service: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? self.service,
            kSecAttrAccount as String: account.uuidString
        ]
        if returningData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }
}
