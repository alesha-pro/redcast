import Foundation

/// At most two GETs per press of Check Balance, on a session made for them and torn down after.
enum OpenRouterAccountClient {
    @concurrent
    static func balance(
        for connection: AIConnection
    ) async throws(OpenRouterAccount.Failure) -> OpenRouterBalance {
        guard let baseURL = try? AIEndpointPolicy.validate(connection.baseURL) else {
            throw .invalidEndpoint
        }
        let stored: String?
        do {
            stored = try KeychainSecretStore.aiAPIKeys.secret(for: connection.id)
        } catch {
            throw .unreadableKey
        }
        guard let key = stored, !key.isEmpty else { throw .missingKey }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        func get(_ path: String) async throws(OpenRouterAccount.Failure) -> Data {
            try await body(of: OpenRouterAccount.request(path, baseURL: baseURL, key: key), on: session)
        }
        let status = try OpenRouterAccount.decodeKey(try await get("key"))
        guard status.isManagementKey == true else {
            return OpenRouterBalance(key: status, credits: nil)
        }
        // Only a management key reads the account: a refusal here is no balance, not a failure.
        let credits = try? OpenRouterAccount.decodeCredits(try await get("credits"))
        return OpenRouterBalance(key: status, credits: credits)
    }

    /// Per call rather than static: a check made this rarely keeps no session alive.
    private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }

    private static func body(
        of request: URLRequest, on session: URLSession
    ) async throws(OpenRouterAccount.Failure) -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw .unavailable
        }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OpenRouterAccount.failure(forStatus: status) }
        return result.0
    }
}
