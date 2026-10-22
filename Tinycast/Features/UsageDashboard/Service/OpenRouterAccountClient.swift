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
        let managementKey = storedManagementKey(for: connection.id)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let status = try OpenRouterAccount.decodeKey(
            try await body(of: OpenRouterAccount.request("key", baseURL: baseURL, key: key), on: session))
        let credits: OpenRouterBalance.Credits
        switch managementKey {
        case .failure(let failure):
            credits = .failed(failure)
        case .success(let managed?):
            credits = await self.credits(
                OpenRouterAccount.creditsRequest(managementKey: managed), managementKey: true, on: session)
        case .success(nil) where status.isManagementKey == true:
            credits = await self.credits(
                OpenRouterAccount.request("credits", baseURL: baseURL, key: key), managementKey: false,
                on: session)
        case .success(nil):
            credits = .needsManagementKey
        }
        return OpenRouterBalance(key: status, credits: credits)
    }

    private static func storedManagementKey(for id: UUID) -> Result<String?, OpenRouterAccount.Failure> {
        do {
            let stored = try KeychainSecretStore.openRouterManagementKeys.secret(for: id)
            return .success(stored?.isEmpty == false ? stored : nil)
        } catch {
            return .failure(.unreadableKey)
        }
    }

    /// The account's credits are a line of their own, so failing them never hides the key's spend.
    private static func credits(
        _ request: URLRequest, managementKey: Bool, on session: URLSession
    ) async -> OpenRouterBalance.Credits {
        do throws(OpenRouterAccount.Failure) {
            let data = try await body(of: request, on: session, managementKey: managementKey)
            return .loaded(try OpenRouterAccount.decodeCredits(data))
        } catch {
            return .failed(error)
        }
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
        of request: URLRequest, on session: URLSession, managementKey: Bool = false
    ) async throws(OpenRouterAccount.Failure) -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw .unavailable
        }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw OpenRouterAccount.failure(forStatus: status, managementKey: managementKey)
        }
        return result.0
    }
}
