import Foundation

/// `GET /key` for the key chats use: its spend per UTC day, week and month, and what it may spend.
struct OpenRouterKeyStatus: Decodable, Equatable, Sendable {
    /// Optional throughout: a budget's shape is the newest part of the API and may still move.
    struct Budget: Decodable, Equatable, Sendable {
        let limitUSD: Double?
        let spendUSD: Double?
        let remainingUSD: Double?
        let resetInterval: String?
        let resetsAt: String?

        private enum CodingKeys: String, CodingKey {
            case limitUSD = "limit_usd"
            case spendUSD = "spend_usd"
            case remainingUSD = "remaining_usd"
            case resetInterval = "reset_interval"
            case resetsAt = "resets_at"
        }
    }

    let label: String?
    let limit: Double?
    let limitRemaining: Double?
    let limitReset: String?
    let usage: Double
    let usageDaily: Double
    let usageWeekly: Double
    let usageMonthly: Double
    let isManagementKey: Bool?
    let isFreeTier: Bool?
    let effectiveBudget: Budget?

    /// The effective budget is the one that binds, so it speaks before the key's own limit.
    var spendingLimit: (remaining: Double, limit: Double)? {
        if let limit = effectiveBudget?.limitUSD, let remaining = effectiveBudget?.remainingUSD {
            return (remaining, limit)
        }
        guard let limit, let remaining = limitRemaining else { return nil }
        return (remaining, limit)
    }

    // Spelled out: `convertFromSnakeCase` would read `limit_usd` as `limitUsd`.
    private enum CodingKeys: String, CodingKey {
        case label
        case limit
        case limitRemaining = "limit_remaining"
        case limitReset = "limit_reset"
        case usage
        case usageDaily = "usage_daily"
        case usageWeekly = "usage_weekly"
        case usageMonthly = "usage_monthly"
        case isManagementKey = "is_management_key"
        case isFreeTier = "is_free_tier"
        case effectiveBudget = "effective_budget"
    }
}

/// `GET /credits`, which only a management key may read.
struct OpenRouterCredits: Decodable, Equatable, Sendable {
    let totalCredits: Double
    let totalUsage: Double

    var remaining: Double { totalCredits - totalUsage }

    private enum CodingKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }
}

struct OpenRouterBalance: Equatable, Sendable {
    enum Credits: Equatable, Sendable {
        case loaded(OpenRouterCredits)
        /// No management key is stored, and the chat's own key is not one.
        case needsManagementKey
        case failed(OpenRouterAccount.Failure)
    }

    let key: OpenRouterKeyStatus
    let credits: Credits
}

/// The pure half of the balance check: requests, decoding and what a status means.
enum OpenRouterAccount {
    enum Failure: Error, Equatable, Sendable {
        case invalidEndpoint
        case missingKey
        case unreadableKey
        case rejectedKey
        case rejectedManagementKey
        case unavailable
        case malformed

        var message: String {
            switch self {
            case .invalidEndpoint: String(localized: "Enter a valid provider base URL.")
            case .missingKey: String(localized: "Add an API key in Settings.")
            case .unreadableKey: String(localized: "The API key could not be read from Keychain.")
            case .rejectedKey: String(localized: "OpenRouter rejected the key.")
            case .rejectedManagementKey: String(localized: "OpenRouter rejected the management key.")
            case .unavailable, .malformed: String(localized: "OpenRouter didn't answer. Try again.")
            }
        }
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        let data: Payload
    }

    static let timeout: TimeInterval = 15

    /// Fixed rather than the connection's base URL: a proxy in between never sees an account key.
    static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!

    /// The one request a management key is ever sent with.
    static func creditsRequest(managementKey: String) -> URLRequest {
        authorized(URLRequest(url: creditsURL, timeoutInterval: timeout), key: managementKey)
    }

    static func request(_ path: String, baseURL: URL, key: String) -> URLRequest {
        authorized(
            URLRequest(url: root(of: baseURL).appending(path: path), timeoutInterval: timeout), key: key)
    }

    private static func authorized(_ request: URLRequest, key: String) -> URLRequest {
        var request = request
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// A base URL written down to `/chat/completions` still names the API root above it.
    private static func root(of baseURL: URL) -> URL {
        guard baseURL.path().hasSuffix("/chat/completions") else { return baseURL }
        return baseURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    static func decodeKey(_ data: Data) throws(Failure) -> OpenRouterKeyStatus {
        try decode(data)
    }

    static func decodeCredits(_ data: Data) throws(Failure) -> OpenRouterCredits {
        try decode(data)
    }

    private static func decode<Payload: Decodable>(_ data: Data) throws(Failure) -> Payload {
        do {
            return try JSONDecoder().decode(Envelope<Payload>.self, from: data).data
        } catch {
            throw .malformed
        }
    }

    /// Only the key's own refusal is the user's to fix; anything else is OpenRouter's.
    static func failure(forStatus status: Int, managementKey: Bool = false) -> Failure {
        guard status == 401 || status == 403 else { return .unavailable }
        return managementKey ? .rejectedManagementKey : .rejectedKey
    }
}
