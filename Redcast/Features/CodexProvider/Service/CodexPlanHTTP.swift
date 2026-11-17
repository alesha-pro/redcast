import Foundation

/// OpenAI's sign-in and catalog requests, on a private session that keeps nothing.
enum CodexPlanHTTP {
    struct Refused: Error, Equatable {
        let status: Int
        let body: Data
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// A token endpoint that redirects is not one to follow with a refresh token in the body.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    @concurrent
    static func send(_ request: URLRequest, limit: Int = 4 * 1_048_576) async throws -> (Data, Int) {
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw CodexPlanOAuth.Failure.network }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw CodexPlanOAuth.Failure.network }
                data.append(byte)
            }
            return (data, response.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as CodexPlanOAuth.Failure {
            throw failure
        } catch {
            try Task.checkCancellation()
            throw CodexPlanOAuth.Failure.network
        }
    }

    static func token(_ form: Data, now: @Sendable () -> Date = Date.init) async throws
        -> CodexPlanOAuth.TokenResponse
    {
        var request = URLRequest(url: CodexPlanOAuth.tokenEndpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = form
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await send(request)
        guard status == 200 else { throw Refused(status: status, body: data) }
        return try CodexPlanOAuth.parseToken(data, now: now())
    }

    /// True only on the empty 200 that confirms it; the caller tells the reader otherwise.
    static func revoke(clientID: String, refreshToken: String) async -> Bool {
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            do {
                let (discovery, found) = try await send(
                    URLRequest(url: CodexPlanOAuth.discoveryURL, timeoutInterval: 15))
                guard found == 200, let endpoint = CodexPlanOAuth.revocationEndpoint(in: discovery) else {
                    continue
                }
                var request = URLRequest(url: endpoint, timeoutInterval: 15)
                request.httpMethod = "POST"
                request.httpBody = CodexPlanOAuth.revocationForm(clientID: clientID, refreshToken: refreshToken)
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                let (_, status) = try await send(request)
                if status == 200 { return true }
                if status < 500 { return false }
            } catch {
                if Task.isCancelled { return false }
            }
        }
        return false
    }

    static func models(accessToken: String) async throws -> [CodexPlanCatalog.Model] {
        var request = URLRequest(url: CodexPlanCatalog.endpoint, timeoutInterval: 30)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await send(request)
        guard status == 200 else { throw Refused(status: status, body: data) }
        guard let models = CodexPlanCatalog.parse(data) else { throw CodexPlanOAuth.Failure.network }
        return models
    }
}

/// The login Keychain item per connection, and the last limits snapshot beside the app's data.
struct CodexPlanStore: Sendable {
    var keychain = KeychainSecretStore.codexPlanCredentials
    var limitsFile = AppPaths.applicationSupport()
        .appending(path: "CodexPlan/limits.json", directoryHint: .notDirectory)

    func credentials(for id: UUID) throws -> CodexPlanCredentials? {
        guard let stored = try keychain.secret(for: id) else { return nil }
        return try? JSONDecoder().decode(CodexPlanCredentials.self, from: Data(stored.utf8))
    }

    func save(_ credentials: CodexPlanCredentials, for id: UUID) throws {
        guard let text = String(data: try JSONEncoder().encode(credentials), encoding: .utf8) else {
            throw KeychainSecretStore.StoreError.invalidEncoding
        }
        try keychain.setSecret(text, for: id)
    }

    func remove(_ id: UUID) throws { try keychain.removeSecret(for: id) }

    func limits() -> [UUID: CodexPlanLimits] {
        guard let data = try? Data(contentsOf: limitsFile),
            let stored = try? JSONDecoder().decode([String: CodexPlanLimits].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    func saveLimits(_ limits: [UUID: CodexPlanLimits]) {
        let keyed = Dictionary(uniqueKeysWithValues: limits.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(keyed) else { return }
        try? FileManager.default.createDirectory(
            at: limitsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: limitsFile, options: .atomic)
    }
}
