import AppKit
import CryptoKit
import Observation
import Security

/// Every Codex (ChatGPT) sign-in, token and limits snapshot; nothing runs until something asks.
@MainActor
@Observable
final class CodexPlanAccounts {
    enum Phase: Equatable {
        case signedOut
        case signingIn
        case signedIn
        case signInRequired
        case failed(String)
    }

    struct Account: Equatable {
        let email: String?
        let planTitle: String?
        let usesPlan: Bool
    }

    private(set) var phases: [UUID: Phase] = [:]
    private(set) var accounts: [UUID: Account] = [:]
    private(set) var limits: [UUID: CodexPlanLimits] = [:]
    private(set) var loadingModels: Set<UUID> = []
    private(set) var modelFailures: [UUID: String] = [:]

    @ObservationIgnored private let settings: AISettingsStore
    @ObservationIgnored private let store: CodexPlanStore
    @ObservationIgnored private let showMessage: (String) -> Void
    @ObservationIgnored private var loaded: Set<UUID> = []
    @ObservationIgnored private var limitsLoaded = false
    @ObservationIgnored private var revisions: [UUID: UUID] = [:]
    @ObservationIgnored private var refreshes: [UUID: Task<String, Error>] = [:]
    @ObservationIgnored private var listener: CodexPlanCallbackListener?
    @ObservationIgnored private var signingIn: UUID?

    init(
        settings: AISettingsStore, store: CodexPlanStore = CodexPlanStore(),
        showMessage: @escaping (String) -> Void
    ) {
        self.settings = settings
        self.store = store
        self.showMessage = showMessage
    }

    func phase(for id: UUID) -> Phase { phases[id] ?? .signedOut }

    var isSigningIn: Bool { signingIn != nil }

    /// Read when a pane that shows them opens, so a view body never touches the Keychain.
    func load(_ connections: [AIConnection]) {
        for connection in connections where connection.provider == .codexPlan {
            guard loaded.insert(connection.id).inserted else { continue }
            do {
                publish(try store.credentials(for: connection.id), for: connection.id)
            } catch {
                phases[connection.id] = .failed(String(localized: "The login Keychain could not be accessed."))
            }
        }
        loadLimits()
    }

    func loadLimits() {
        guard !limitsLoaded else { return }
        limitsLoaded = true
        limits.merge(store.limits()) { live, _ in live }
    }

    func add() -> UUID {
        let connection = AIConnection(provider: .codexPlan)
        settings.save(connection)
        loaded.insert(connection.id)
        phases[connection.id] = .signedOut
        return connection.id
    }

    // MARK: Sign in and out

    func signIn(_ id: UUID) {
        guard signingIn == nil else { return }
        signingIn = id
        phases[id] = .signingIn
        Task { await runSignIn(id) }
    }

    func cancelSignIn(_ id: UUID) {
        guard signingIn == id else { return }
        revisions[id] = UUID()
        listener?.cancel()
        publish(try? store.credentials(for: id), for: id)
    }

    func signOut(_ id: UUID) {
        cancelSignIn(id)
        revisions[id] = UUID()
        refreshes.removeValue(forKey: id)?.cancel()
        guard var credentials = try? store.credentials(for: id) else {
            phases[id] = .signedOut
            return
        }
        let grant = credentials.clientID.flatMap { client in
            credentials.token?.refreshToken.map { (client, $0) }
        }
        credentials.token = nil
        credentials.idToken = nil
        do {
            try store.save(credentials, for: id)
        } catch {
            phases[id] = .failed(String(localized: "The login Keychain could not be accessed."))
            return
        }
        publish(credentials, for: id)
        revoke(grant)
    }

    /// The connection is gone: its session is revoked and its Keychain item and snapshot deleted.
    func forget(_ id: UUID) {
        cancelSignIn(id)
        revisions[id] = UUID()
        refreshes.removeValue(forKey: id)?.cancel()
        let credentials = try? store.credentials(for: id)
        try? store.remove(id)
        let grant = credentials?.clientID.flatMap { client in
            credentials?.token?.refreshToken.map { (client, $0) }
        }
        phases[id] = nil
        accounts[id] = nil
        loaded.remove(id)
        if limits.removeValue(forKey: id) != nil { persistLimits() }
        revoke(grant)
    }

    private func revoke(_ grant: (clientID: String, refreshToken: String)?) {
        guard let grant else { return }
        Task {
            guard await !CodexPlanHTTP.revoke(clientID: grant.clientID, refreshToken: grant.refreshToken)
            else { return }
            showMessage(
                String(
                    localized: """
                        Signed out on this Mac, but OpenAI did not confirm it. Disconnect the app in \
                        ChatGPT settings if you need to.
                        """))
        }
    }

    private func runSignIn(_ id: UUID) async {
        let revision = UUID()
        revisions[id] = revision
        refreshes.removeValue(forKey: id)?.cancel()
        let callback = CodexPlanCallbackListener()
        listener = callback
        defer {
            callback.cancel()
            listener = nil
            signingIn = nil
        }
        do {
            var credentials =
                try store.credentials(for: id) ?? CodexPlanCredentials(hostID: CodexPlanOAuth.hostID(UUID()))
            // The host id is persisted before the first sign-in, as the registration expects.
            try store.save(credentials, for: id)
            let pkce = CodexPlanOAuth.pkce(entropy: try Self.random(64)) { Data(SHA256.hash(data: $0)) }
            let state = CodexPlanOAuth.base64URL(try Self.random(32))
            let nonce = CodexPlanOAuth.base64URL(try Self.random(32))
            try await callback.start(state: state)
            let url = CodexPlanOAuth.authorizeURL(
                CodexPlanOAuth.Authorization(
                    clientID: credentials.clientID, hostID: credentials.hostID,
                    appName: Bundle.main.appDisplayName, idTokenHint: credentials.idToken,
                    loginHint: credentials.email, state: state, nonce: nonce, challenge: pkce.challenge))
            try check(id, revision)
            guard NSWorkspace.shared.open(url) else { throw CodexPlanOAuth.Failure.network }
            let returned = try await callback.callback()
            let clientID = try CodexPlanOAuth.issuedClientID(
                saved: credentials.clientID, returned: returned.clientID)
            let response = try await CodexPlanHTTP.token(
                CodexPlanOAuth.exchangeForm(clientID: clientID, code: returned.code, verifier: pkce.verifier))
            try check(id, revision)
            guard let idToken = response.idToken else { throw CodexPlanOAuth.Failure.invalidToken }
            let identity = try CodexPlanOAuth.identity(idToken, clientID: clientID, nonce: nonce, now: Date())
            if let subject = credentials.subject, subject != identity.subject {
                throw CodexPlanOAuth.Failure.accountMismatch
            }
            let welcomes = credentials.subject == nil
            credentials.clientID = clientID
            credentials.subject = identity.subject
            credentials.email = identity.email
            credentials.plan = identity.plan
            credentials.apply(response)
            try store.save(credentials, for: id)
            publish(credentials, for: id)
            if welcomes, credentials.usesPlan {
                showMessage(String(localized: "You’re using your ChatGPT plan"))
            }
            await loadModels(id)
        } catch {
            guard revisions[id] == revision else { return }
            if error is CancellationError {
                publish(try? store.credentials(for: id), for: id)
            } else {
                phases[id] = .failed(Self.describe(error))
            }
        }
    }

    // MARK: Tokens

    /// One refresh at a time per connection: the refresh token rotates, so a second would spend it.
    func accessToken(for id: UUID, rejected: String? = nil) async throws -> String {
        let credentials: CodexPlanCredentials?
        do {
            credentials = try store.credentials(for: id)
        } catch {
            throw AIProviderError.unavailable(String(localized: "The login Keychain could not be accessed."))
        }
        guard let credentials, let clientID = credentials.clientID, let token = credentials.token else {
            throw AIProviderError.unavailable(
                credentials?.idToken == nil
                    ? String(localized: "Sign in with ChatGPT in Settings → AI → Providers.")
                    : CodexPlanFailure.signInRequired.message(now: Date()))
        }
        guard credentials.usesPlan else {
            throw AIProviderError.unavailable(
                String(localized: "This sign-in did not allow ChatGPT plan usage. Sign out and sign in again."))
        }
        if let pending = refreshes[id] { return try await pending.value }
        switch CodexPlanOAuth.decision(for: token, now: Date(), rejected: rejected == token.accessToken) {
        case .use:
            return token.accessToken
        case .signInRequired:
            expire(id)
            throw AIProviderError.unavailable(CodexPlanFailure.signInRequired.message(now: Date()))
        case .refresh:
            break
        }
        let revision = revisions[id] ?? UUID()
        revisions[id] = revision
        let task = Task { [weak self] in
            let response = try await Self.refreshed(clientID: clientID, token: token)
            guard let self else { throw CancellationError() }
            try self.check(id, revision)
            guard var stored = try self.store.credentials(for: id), stored.clientID == clientID else {
                throw CancellationError()
            }
            stored.apply(response)
            if let idToken = response.idToken,
                let identity = try? CodexPlanOAuth.identity(idToken, clientID: clientID, nonce: nil, now: Date()),
                identity.subject == stored.subject
            {
                stored.email = identity.email ?? stored.email
                stored.plan = identity.plan ?? stored.plan
            }
            try self.store.save(stored, for: id)
            self.publish(stored, for: id)
            return response.accessToken
        }
        refreshes[id] = task
        defer { if refreshes[id] == task { refreshes[id] = nil } }
        do {
            return try await task.value
        } catch let failure as CodexPlanOAuth.RefreshFailure {
            switch failure {
            case .signInRequired:
                if revisions[id] == revision { expire(id) }
                throw AIProviderError.unavailable(CodexPlanFailure.signInRequired.message(now: Date()))
            case .invalidClient:
                throw AIProviderError.unavailable(
                    String(localized: "OpenAI no longer accepts this sign-in. Sign out and sign in again."))
            case .transient:
                throw AIProviderRecoverableError(
                    kind: .transient(retryAfter: nil),
                    message: String(localized: "The ChatGPT sign-in could not be refreshed. Try again shortly."))
            }
        }
    }

    private static func refreshed(
        clientID: String, token: CodexPlanCredentials.Token
    ) async throws -> CodexPlanOAuth.TokenResponse {
        guard let refreshToken = token.refreshToken else { throw CodexPlanOAuth.RefreshFailure.signInRequired }
        do {
            return try await CodexPlanHTTP.token(
                CodexPlanOAuth.refreshForm(clientID: clientID, refreshToken: refreshToken))
        } catch let refused as CodexPlanHTTP.Refused {
            throw CodexPlanOAuth.refreshFailure(status: refused.status, body: refused.body)
        } catch is CodexPlanOAuth.Failure {
            throw CodexPlanOAuth.RefreshFailure.transient
        }
    }

    /// A spent grant: the tokens go, the client and the last ID token stay for signing in again.
    private func expire(_ id: UUID) {
        guard var credentials = try? store.credentials(for: id), credentials.token != nil else { return }
        credentials.token = nil
        try? store.save(credentials, for: id)
        publish(credentials, for: id)
        phases[id] = .signInRequired
    }

    // MARK: Models and limits

    func loadModels(_ id: UUID) async {
        guard loadingModels.insert(id).inserted else { return }
        defer { loadingModels.remove(id) }
        do {
            var token = try await accessToken(for: id)
            let models: [CodexPlanCatalog.Model]
            do {
                models = try await CodexPlanHTTP.models(accessToken: token)
            } catch let refused as CodexPlanHTTP.Refused where refused.status == 401 {
                token = try await accessToken(for: id, rejected: token)
                models = try await CodexPlanHTTP.models(accessToken: token)
            }
            guard var connection = settings.connection(id: id) else { return }
            CodexPlanCatalog.apply(models, to: &connection)
            settings.save(connection)
            modelFailures[id] = nil
        } catch is CancellationError {
            return
        } catch {
            modelFailures[id] = Self.describe(error)
        }
    }

    func record(_ snapshot: CodexPlanLimits, for id: UUID) {
        guard settings.connection(id: id) != nil else { return }
        loadLimits()
        limits[id] = snapshot
        persistLimits()
    }

    private func persistLimits() {
        let store = store
        let snapshot = limits
        Task.detached { store.saveLimits(snapshot) }
    }

    func provider(for connection: AIConnection, model: String, effort: String?) -> CodexPlanProvider {
        let id = connection.id
        return CodexPlanProvider(
            model: model, effort: connection.offeredEffort(effort, for: model),
            reasons: connection.reasoningOptions(for: model) != nil,
            replay: connection.reasoningReplay,
            token: { [weak self] rejected in
                guard let self else { throw CancellationError() }
                return try await self.accessToken(for: id, rejected: rejected)
            },
            record: { [weak self] snapshot in self?.record(snapshot, for: id) })
    }

    // MARK: Helpers

    private func publish(_ credentials: CodexPlanCredentials?, for id: UUID) {
        guard let credentials, credentials.token != nil else {
            accounts[id] = nil
            // Sign Out drops the ID token; an expired grant keeps it to sign in again.
            phases[id] = credentials?.idToken == nil ? .signedOut : .signInRequired
            return
        }
        accounts[id] = Account(
            email: credentials.email, planTitle: credentials.planTitle, usesPlan: credentials.usesPlan)
        phases[id] = .signedIn
    }

    private func check(_ id: UUID, _ revision: UUID) throws {
        try Task.checkCancellation()
        guard revisions[id] == revision else { throw CancellationError() }
    }

    private static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw CodexPlanOAuth.Failure.invalidToken
        }
        return Data(bytes)
    }

    private static func describe(_ error: Error) -> String {
        if let refused = error as? CodexPlanHTTP.Refused {
            let said = CodexPlanFailure.detail(in: JSONValue(data: refused.body)).message
            return said.map { AIProviderFailure.kept($0, secrets: []) }
                ?? String(localized: "OpenAI refused the sign-in (HTTP \(refused.status)).")
        }
        return error.localizedDescription
    }
}
