import Foundation

/// OpenAI's Sign in with ChatGPT for open-source apps; codex-provider.md cites each rule.
enum CodexPlanOAuth {
    static let issuer = "https://auth.openai.com"
    static let authorizeEndpoint = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    static let resource = "https://api.openai.com/v1"
    static let registeringClientID = "dynamic_agent_client"
    static let planScope = "chatgpt.tokens.use.direct"
    static let scope = "openid profile email offline_access resource.invoke " + planScope
    static let callbackPath = "/auth/callback"
    static let callbackPort: UInt16 = 4965
    static var redirectURI: String { "http://127.0.0.1:\(callbackPort)\(callbackPath)" }

    enum Failure: LocalizedError, Equatable {
        case invalidCallback
        case denied
        case missingClient
        case clientMismatch
        case invalidToken
        case accountMismatch
        case timedOut
        case listenerUnavailable
        case signInInProgress
        case network

        var errorDescription: String? {
            switch self {
            case .invalidCallback, .missingClient, .clientMismatch, .invalidToken:
                return String(localized: "OpenAI returned a sign-in Tinycast could not verify.")
            case .denied: return String(localized: "Sign-in was cancelled in the browser.")
            case .accountMismatch:
                return String(localized: "That is a different ChatGPT account. Add another connection for it.")
            case .timedOut: return String(localized: "Sign-in timed out. Try again.")
            case .listenerUnavailable:
                return String(localized: "Tinycast could not open its sign-in callback on this Mac.")
            case .signInInProgress: return String(localized: "Another sign-in is already in progress.")
            case .network: return String(localized: "The provider could not be reached.")
            }
        }
    }

    // MARK: PKCE and the authorize URL

    static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func pkce(entropy: Data, sha256: (Data) -> Data) -> (verifier: String, challenge: String) {
        let verifier = base64URL(entropy)
        return (verifier, base64URL(sha256(Data(verifier.utf8))))
    }

    /// Opaque and stable per connection; never an email or account id.
    static func hostID(_ uuid: UUID) -> String { "urn:uuid:" + uuid.uuidString.lowercased() }

    struct Authorization: Equatable, Sendable {
        let clientID: String?
        let hostID: String
        let appName: String
        let idTokenHint: String?
        let loginHint: String?
        let state: String
        let nonce: String
        let challenge: String
    }

    /// A saved client reauthorizes; only a first registration names the app.
    static func authorizeURL(_ request: Authorization) -> URL {
        var fields: [(String, String)] = [
            ("client_id", request.clientID ?? registeringClientID),
            ("ext_agent_host_id", request.hostID),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", scope),
            ("resource", resource),
            ("state", request.state),
            ("nonce", request.nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", request.challenge)
        ]
        if request.clientID == nil {
            fields.append(("agent_name_hint", request.appName))
        } else {
            if let hint = request.idTokenHint { fields.append(("id_token_hint", hint)) }
            if let hint = request.loginHint { fields.append(("login_hint", hint)) }
        }
        var parts = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        parts.percentEncodedQuery = fields.map { "\(escape($0.0))=\(escape($0.1))" }
            .joined(separator: "&")
        return parts.url!
    }

    static func escape(_ value: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func form(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&").utf8)
    }

    // MARK: The callback

    struct Callback: Equatable, Sendable {
        let code: String
        let clientID: String?
    }

    /// State is checked before anything else, so a stray request can neither deny nor sign in.
    static func callback(_ target: String, state: String) throws -> Callback {
        guard target.hasPrefix(callbackPath + "?"),
            let parts = URLComponents(string: "http://127.0.0.1" + target),
            parts.path == callbackPath, parts.fragment == nil
        else { throw Failure.invalidCallback }
        var fields: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard fields[item.name] == nil else { throw Failure.invalidCallback }
            fields[item.name] = item.value ?? ""
        }
        guard fields["state"] == state else { throw Failure.invalidCallback }
        if fields["error"] != nil { throw Failure.denied }
        guard let code = fields["code"], !code.isEmpty else { throw Failure.invalidCallback }
        return Callback(code: code, clientID: fields["client_id"].flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A first sign-in must be issued its own client; a reauthorization must keep the saved one.
    static func issuedClientID(saved: String?, returned: String?) throws -> String {
        if let saved {
            if let returned, returned != saved { throw Failure.clientMismatch }
            return saved
        }
        guard let returned, returned != registeringClientID else { throw Failure.missingClient }
        return returned
    }

    // MARK: Token requests

    static func exchangeForm(clientID: String, code: String, verifier: String) -> Data {
        form([
            ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
            ("code_verifier", verifier), ("redirect_uri", redirectURI), ("resource", resource)
        ])
    }

    /// No `scope`, so the grant keeps what was consented.
    static func refreshForm(clientID: String, refreshToken: String) -> Data {
        form([
            ("grant_type", "refresh_token"), ("client_id", clientID),
            ("refresh_token", refreshToken), ("resource", resource)
        ])
    }

    static func revocationForm(clientID: String, refreshToken: String) -> Data {
        form([("token", refreshToken), ("token_type_hint", "refresh_token"), ("client_id", clientID)])
    }

    /// Only an endpoint on OpenAI's own sign-in host is ever sent a refresh token.
    static func revocationEndpoint(in discovery: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: discovery) as? [String: Any],
            let value = json["revocation_endpoint"] as? String, let url = URL(string: value),
            url.scheme == "https", url.host() == URL(string: issuer)?.host()
        else { return nil }
        return url
    }

    struct TokenResponse: Equatable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let expiresAt: Date
        let earliestRefreshAt: Date?
        let scopes: [String]?
    }

    static func parseToken(_ data: Data, now: Date) throws -> TokenResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String, !access.isEmpty,
            access.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
            ((json["token_type"] as? String)?.lowercased() ?? "bearer") == "bearer"
        else { throw Failure.invalidToken }
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3_600
        guard lifetime.isFinite, lifetime > 0 else { throw Failure.invalidToken }
        let scopes: [String]? =
            (json["scope"] as? String).map { $0.split(separator: " ").map(String.init) }
            ?? (json["scopes"] as? [String])
        return TokenResponse(
            accessToken: access,
            refreshToken: (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            idToken: (json["id_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            expiresAt: now.addingTimeInterval(lifetime),
            earliestRefreshAt: date(json["earliest_refresh_at"]),
            scopes: scopes)
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = (value as? NSNumber)?.doubleValue, seconds.isFinite, seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        return (try? Date(text, strategy: .iso8601)) ?? Double(text).map(Date.init(timeIntervalSince1970:))
    }

    // MARK: The ID token

    struct Identity: Equatable, Sendable {
        let subject: String
        let email: String?
        let plan: String?
    }

    /// Received straight from the token endpoint over TLS, so its claims are checked, not its key.
    static func identity(
        _ idToken: String, clientID: String, nonce: String?, now: Date, leeway: TimeInterval = 120
    ) throws -> Identity {
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, let payload = base64URLDecoded(String(segments[1])),
            let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            claims["iss"] as? String == issuer,
            let subject = claims["sub"] as? String, !subject.isEmpty,
            audiences(claims["aud"]).contains(clientID),
            let exp = (claims["exp"] as? NSNumber)?.doubleValue,
            now.timeIntervalSince1970 < exp + leeway
        else { throw Failure.invalidToken }
        if let nonce, claims["nonce"] as? String != nonce { throw Failure.invalidToken }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        let email = (claims["email"] as? String) ?? (profile?["email"] as? String)
        return Identity(subject: subject, email: email, plan: auth?["chatgpt_plan_type"] as? String)
    }

    private static func audiences(_ value: Any?) -> [String] {
        if let one = value as? String { return [one] }
        return value as? [String] ?? []
    }

    static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    // MARK: Refresh

    enum RefreshDecision: Equatable {
        case use
        case refresh
        case signInRequired
    }

    /// Lazy: a token is refreshed only when a request is about to need it.
    static func decision(
        for token: CodexPlanCredentials.Token?, now: Date, rejected: Bool, margin: TimeInterval = 60
    ) -> RefreshDecision {
        guard let token else { return .signInRequired }
        let canRefresh = token.refreshToken != nil
        if rejected { return canRefresh ? .refresh : .signInRequired }
        if now < token.expiresAt.addingTimeInterval(-margin) { return .use }
        guard canRefresh else { return now < token.expiresAt ? .use : .signInRequired }
        if let earliest = token.earliestRefreshAt, now < earliest, now < token.expiresAt { return .use }
        return .refresh
    }

    enum RefreshFailure: Error, Equatable {
        /// The grant is spent: the tokens go, and the account signs in again.
        case signInRequired
        case invalidClient
        /// Offline or a server fault: the tokens stay for the next request.
        case transient
    }

    private static let spentGrants: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
        "refresh_token_invalidated", "refresh_token_reused"
    ]

    static func refreshFailure(status: Int, body: Data) -> RefreshFailure {
        let code = errorCode(in: body)
        if code == "invalid_client" { return .invalidClient }
        if let code, spentGrants.contains(code) { return .signInRequired }
        // RFC 6749 §5.2: only 400 and 401 reject the grant; anything else is a server fault.
        return status == 400 || status == 401 ? .signInRequired : .transient
    }

    static func errorCode(in body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let code = json["error"] as? String { return code }
        let error = json["error"] as? [String: Any]
        return (error?["code"] as? String) ?? (error?["type"] as? String) ?? (json["code"] as? String)
    }
}

/// One connection's sign-in, kept as one login Keychain item; the client and host outlive sign-out.
struct CodexPlanCredentials: Codable, Equatable, Sendable {
    struct Token: Codable, Equatable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var earliestRefreshAt: Date?
        var scopes: [String]
    }

    var hostID: String
    var clientID: String?
    var subject: String?
    var email: String?
    var plan: String?
    /// The last sign-in's, sent back as `id_token_hint`; dropped by Sign Out.
    var idToken: String?
    var token: Token?

    init(hostID: String) { self.hostID = hostID }

    /// A grant without plan usage stays signed in, but its requests would bill nothing to the plan.
    var usesPlan: Bool { token?.scopes.contains(CodexPlanOAuth.planScope) == true }

    /// A refresh replaces the token set together; a missing refresh token keeps the old one.
    mutating func apply(_ response: CodexPlanOAuth.TokenResponse) {
        token = Token(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? token?.refreshToken,
            expiresAt: response.expiresAt, earliestRefreshAt: response.earliestRefreshAt,
            scopes: response.scopes ?? token?.scopes ?? [])
        if let idToken = response.idToken { self.idToken = idToken }
    }

    var planTitle: String? {
        guard let plan else { return nil }
        switch plan {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "business", "self_serve_business_prolite", "self_serve_business_usage_based": return "Business"
        case "enterprise", "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based":
            return "Enterprise"
        case "edu", "edu_plus", "edu_pro": return "Edu"
        default: return nil
        }
    }
}
