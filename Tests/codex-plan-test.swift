import CryptoKit
import Foundation

@main
struct CodexPlanTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func main() {
        pkceMatchesTheRFCVector()
        authorizeURLRegistersOnceThenReauthorizes()
        callbacksCheckStateBeforeAnything()
        issuedClientIDsFollowTheRegistrationRules()
        tokenFormsCarryOnlyWhatTheFlowDefines()
        tokenResponsesDecodeWithTheirExpiry()
        idTokensAreCheckedClaimByClaim()
        refreshHappensOnlyWhenARequestNeedsIt()
        refreshFailuresSpendTheGrantOnlyWhenRejected()
        credentialsKeepTheirRefreshTokenAcrossRotation()
        revocationGoesOnlyToOpenAIsHost()
        textStreamYieldsReasoningAnswerUsageAndLimits()
        toolStreamHandsCallsToTheLoopInOrder()
        failedStreamCarriesItsCode()
        incompleteStreamReportsTheCap()
        headersBecomeASnapshot()
        failuresMapToClearMessages()
        requestBodiesStayInsideThePlanRoute()
        reasoningGoesBackOnlyToItsOwnModelWithinTheTurn()
        catalogsListOnlyShownModelsWithTheirLevels()
        print("codex-plan-test: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: OAuth

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func query(_ url: URL) -> [String: String] {
        var fields: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            fields[item.name] = item.value
        }
        return fields
    }

    static func form(_ data: Data) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in (String(data: data, encoding: .utf8) ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            fields[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return fields
    }

    static func pkceMatchesTheRFCVector() {
        // RFC 7636 Appendix B: the verifier's octets, and the S256 challenge they must give.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let entropy = CodexPlanOAuth.base64URLDecoded(verifier) ?? Data()
        let pair = CodexPlanOAuth.pkce(entropy: entropy, sha256: sha256)
        expect(pair.verifier == verifier, "the verifier is the octets in unpadded base64url")
        expect(pair.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "the S256 challenge matches")
        let long = CodexPlanOAuth.pkce(entropy: Data(repeating: 7, count: 64), sha256: sha256)
        expect((43...128).contains(long.verifier.count), "64 random bytes make a verifier of legal length")
        expect(!long.verifier.contains("=") && !long.challenge.contains("="), "no padding is ever sent")
        expect(CodexPlanOAuth.hostID(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!)
            == "urn:uuid:6f9619ff-8b86-d011-b42d-00c04fc964ff", "the host id is a lowercase urn:uuid")
    }

    static func authorizeURLRegistersOnceThenReauthorizes() {
        let first = CodexPlanOAuth.authorizeURL(
            .init(
                clientID: nil, hostID: "urn:uuid:1", appName: "Redcast", idTokenHint: "old",
                loginHint: "a@b.c", state: "st", nonce: "no", challenge: "ch"))
        let fields = query(first)
        expect(first.absoluteString.hasPrefix("https://auth.openai.com/api/accounts/authorize?"), "endpoint")
        expect(fields["client_id"] == "dynamic_agent_client", "a first sign-in registers dynamically")
        expect(fields["agent_name_hint"] == "Redcast", "and names the app")
        expect(fields["id_token_hint"] == nil && fields["login_hint"] == nil, "a registration sends no hints")
        expect(fields["redirect_uri"] == "http://127.0.0.1:4965/auth/callback", "loopback IP, never localhost")
        expect(fields["response_type"] == "code" && fields["code_challenge_method"] == "S256", "PKCE code flow")
        expect(fields["code_challenge"] == "ch" && fields["state"] == "st" && fields["nonce"] == "no", "values")
        expect(fields["resource"] == "https://api.openai.com/v1", "the resource is the public API")
        expect(fields["ext_agent_host_id"] == "urn:uuid:1", "the host id rides every sign-in")
        let scopes = Set((fields["scope"] ?? "").split(separator: " ").map(String.init))
        expect(
            scopes == ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"],
            "the scope asks for plan usage and a refresh token")
        let again = query(
            CodexPlanOAuth.authorizeURL(
                .init(
                    clientID: "oaiapp_x", hostID: "urn:uuid:1", appName: "Redcast", idTokenHint: "old",
                    loginHint: "a@b.c", state: "s", nonce: "n", challenge: "c")))
        expect(again["client_id"] == "oaiapp_x", "a saved client reauthorizes")
        expect(again["agent_name_hint"] == nil, "and is not named again")
        expect(again["id_token_hint"] == "old" && again["login_hint"] == "a@b.c", "with the account's hints")
        let encoded = CodexPlanOAuth.authorizeURL(
            .init(
                clientID: nil, hostID: "h", appName: "Red cast&", idTokenHint: nil, loginHint: nil,
                state: "a+b", nonce: "n", challenge: "c"))
        expect(query(encoded)["agent_name_hint"] == "Red cast&", "values are percent-encoded")
        expect(encoded.absoluteString.contains("state=a%2Bb"), "a plus is encoded, never read as a space")
    }

    static func callbacksCheckStateBeforeAnything() {
        let ok = try? CodexPlanOAuth.callback(
            "/auth/callback?code=abc&scope=openid&state=S&client_id=oaiapp_1", state: "S")
        expect(ok == CodexPlanOAuth.Callback(code: "abc", clientID: "oaiapp_1"), "a valid callback")
        let reauth = try? CodexPlanOAuth.callback("/auth/callback?code=abc&state=S", state: "S")
        expect(reauth?.clientID == nil, "a reauthorization may omit the client")
        func failure(_ target: String) -> CodexPlanOAuth.Failure? {
            do {
                _ = try CodexPlanOAuth.callback(target, state: "S")
                return nil
            } catch {
                return error as? CodexPlanOAuth.Failure
            }
        }
        expect(failure("/auth/callback?code=abc&state=T") == .invalidCallback, "a wrong state is refused")
        expect(failure("/auth/callback?error=access_denied&state=T") == .invalidCallback, "even to deny")
        expect(failure("/auth/callback?error=access_denied&state=S") == .denied, "a denial with the state")
        expect(failure("/auth/callback?state=S") == .invalidCallback, "no code, no sign-in")
        expect(failure("/auth/callback?code=a&code=b&state=S") == .invalidCallback, "a repeated field")
        expect(failure("/callback?code=a&state=S") == .invalidCallback, "another path")
        expect(failure("/auth/callback/extra?code=a&state=S") == .invalidCallback, "a longer path")
    }

    static func issuedClientIDsFollowTheRegistrationRules() {
        expect((try? CodexPlanOAuth.issuedClientID(saved: nil, returned: "oaiapp_1")) == "oaiapp_1", "issued")
        expect((try? CodexPlanOAuth.issuedClientID(saved: nil, returned: nil)) == nil, "a registration needs one")
        expect(
            (try? CodexPlanOAuth.issuedClientID(saved: nil, returned: "dynamic_agent_client")) == nil,
            "the registering id is never saved")
        expect((try? CodexPlanOAuth.issuedClientID(saved: "oaiapp_1", returned: nil)) == "oaiapp_1", "kept")
        expect(
            (try? CodexPlanOAuth.issuedClientID(saved: "oaiapp_1", returned: "oaiapp_1")) == "oaiapp_1",
            "the same client again")
        expect(
            (try? CodexPlanOAuth.issuedClientID(saved: "oaiapp_1", returned: "oaiapp_2")) == nil,
            "a different client is rejected")
    }

    static func tokenFormsCarryOnlyWhatTheFlowDefines() {
        let exchange = form(CodexPlanOAuth.exchangeForm(clientID: "oaiapp_1", code: "c/d", verifier: "v"))
        expect(
            exchange == [
                "grant_type": "authorization_code", "client_id": "oaiapp_1", "code": "c/d",
                "code_verifier": "v", "redirect_uri": "http://127.0.0.1:4965/auth/callback",
                "resource": "https://api.openai.com/v1"
            ], "the code exchange")
        let refresh = form(CodexPlanOAuth.refreshForm(clientID: "oaiapp_1", refreshToken: "r"))
        expect(
            refresh == [
                "grant_type": "refresh_token", "client_id": "oaiapp_1", "refresh_token": "r",
                "resource": "https://api.openai.com/v1"
            ], "a refresh omits scope, so the grant keeps what was consented")
        let revoke = form(CodexPlanOAuth.revocationForm(clientID: "oaiapp_1", refreshToken: "r"))
        expect(
            revoke == ["token": "r", "token_type_hint": "refresh_token", "client_id": "oaiapp_1"], "revocation")
    }

    static func tokenResponsesDecodeWithTheirExpiry() {
        let body = Data(
            """
            {"access_token":"at","refresh_token":"rt","id_token":"it","token_type":"Bearer","expires_in":3600,
             "scope":"chatgpt.tokens.use.direct email offline_access openid profile resource.invoke",
             "earliest_refresh_at":1790001800}
            """.utf8)
        let token = try? CodexPlanOAuth.parseToken(body, now: now)
        expect(token?.accessToken == "at" && token?.refreshToken == "rt" && token?.idToken == "it", "fields")
        expect(token?.expiresAt == now.addingTimeInterval(3600), "expiry is now plus expires_in")
        expect(token?.scopes?.contains("chatgpt.tokens.use.direct") == true, "scopes split on spaces")
        expect(token?.earliestRefreshAt == Date(timeIntervalSince1970: 1_790_001_800), "a numeric earliest refresh")
        let iso = try? CodexPlanOAuth.parseToken(
            Data(#"{"access_token":"a","earliest_refresh_at":"2026-09-21T12:00:00Z","scopes":["x"]}"#.utf8),
            now: now)
        expect(iso?.earliestRefreshAt != nil && iso?.scopes == ["x"], "an ISO earliest refresh and a scopes list")
        expect(iso?.expiresAt == now.addingTimeInterval(3600), "a missing lifetime is the documented hour")
        expect(iso?.refreshToken == nil, "no refresh token without offline_access")
        expect((try? CodexPlanOAuth.parseToken(Data(#"{"access_token":"a","token_type":"mac"}"#.utf8), now: now)) == nil,
            "only bearer tokens")
        expect((try? CodexPlanOAuth.parseToken(Data(#"{"access_token":"a b"}"#.utf8), now: now)) == nil,
            "a token that would break the header")
        expect((try? CodexPlanOAuth.parseToken(Data("{}".utf8), now: now)) == nil, "no token, no response")
    }

    static func jwt(_ claims: [String: Any]) -> String {
        let header = CodexPlanOAuth.base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let payload = CodexPlanOAuth.base64URL((try? JSONSerialization.data(withJSONObject: claims)) ?? Data())
        return "\(header).\(payload).c2ln"
    }

    static func idTokensAreCheckedClaimByClaim() {
        let claims: [String: Any] = [
            "iss": "https://auth.openai.com", "aud": ["oaiapp_1"], "sub": "user-1", "nonce": "N",
            "exp": now.timeIntervalSince1970 + 3600, "email": "me@example.com",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"]
        ]
        let identity = try? CodexPlanOAuth.identity(jwt(claims), clientID: "oaiapp_1", nonce: "N", now: now)
        expect(identity == .init(subject: "user-1", email: "me@example.com", plan: "plus"), "the identity")
        func rejects(_ change: (inout [String: Any]) -> Void, nonce: String? = "N", _ message: String) {
            var changed = claims
            change(&changed)
            let result = try? CodexPlanOAuth.identity(jwt(changed), clientID: "oaiapp_1", nonce: nonce, now: now)
            expect(result == nil, message)
        }
        rejects({ $0["iss"] = "https://evil.example" }, "another issuer")
        rejects({ $0["aud"] = "oaiapp_2" }, "another audience")
        rejects({ $0["nonce"] = "M" }, "another nonce")
        rejects({ $0["exp"] = now.timeIntervalSince1970 - 600 }, "an expired token")
        rejects({ $0["sub"] = nil }, "no subject")
        let refreshed = try? CodexPlanOAuth.identity(
            jwt(claims.filter { $0.key != "nonce" }), clientID: "oaiapp_1", nonce: nil, now: now)
        expect(refreshed?.subject == "user-1", "a refresh's ID token has no nonce to check")
        expect((try? CodexPlanOAuth.identity("a.b", clientID: "x", nonce: nil, now: now)) == nil, "not a JWT")
    }

    static func token(
        expiresIn seconds: TimeInterval, refresh: Bool = true, earliest: TimeInterval? = nil
    ) -> CodexPlanCredentials.Token {
        CodexPlanCredentials.Token(
            accessToken: "at", refreshToken: refresh ? "rt" : nil, expiresAt: now.addingTimeInterval(seconds),
            earliestRefreshAt: earliest.map { now.addingTimeInterval($0) }, scopes: [])
    }

    static func refreshHappensOnlyWhenARequestNeedsIt() {
        typealias OAuth = CodexPlanOAuth
        expect(OAuth.decision(for: nil, now: now, rejected: false) == .signInRequired, "no token")
        expect(OAuth.decision(for: token(expiresIn: 3000), now: now, rejected: false) == .use, "a fresh token")
        expect(OAuth.decision(for: token(expiresIn: 30), now: now, rejected: false) == .refresh, "near expiry")
        expect(OAuth.decision(for: token(expiresIn: -10), now: now, rejected: false) == .refresh, "expired")
        expect(OAuth.decision(for: token(expiresIn: 3000), now: now, rejected: true) == .refresh, "refused")
        expect(
            OAuth.decision(for: token(expiresIn: 3000, refresh: false), now: now, rejected: true) == .signInRequired,
            "refused with nothing to refresh it")
        expect(OAuth.decision(for: token(expiresIn: 30, refresh: false), now: now, rejected: false) == .use,
            "a token without a refresh is used to its end")
        expect(
            OAuth.decision(for: token(expiresIn: -1, refresh: false), now: now, rejected: false) == .signInRequired,
            "and then needs a sign-in")
        expect(OAuth.decision(for: token(expiresIn: 30, earliest: 20), now: now, rejected: false) == .use,
            "not before the earliest refresh while still valid")
        expect(OAuth.decision(for: token(expiresIn: -5, earliest: 20), now: now, rejected: false) == .refresh,
            "an expired token refreshes regardless")
    }

    static func refreshFailuresSpendTheGrantOnlyWhenRejected() {
        func body(_ text: String) -> Data { Data(text.utf8) }
        typealias OAuth = CodexPlanOAuth
        for code in ["invalid_grant", "refresh_token_reused", "refresh_token_expired", "token_expired"] {
            expect(
                OAuth.refreshFailure(status: 400, body: body(#"{"error":"\#(code)"}"#)) == .signInRequired, code)
        }
        expect(OAuth.refreshFailure(status: 400, body: body(#"{"error":{"code":"refresh_token_invalidated"}}"#))
            == .signInRequired, "a nested code")
        expect(OAuth.refreshFailure(status: 401, body: body(#"{"error":"invalid_client"}"#)) == .invalidClient,
            "a client problem is not the account's")
        expect(OAuth.refreshFailure(status: 503, body: body("busy")) == .transient, "a server fault keeps tokens")
        expect(OAuth.refreshFailure(status: 400, body: body("")) == .signInRequired, "RFC 6749's rejection")
    }

    static func credentialsKeepTheirRefreshTokenAcrossRotation() {
        var stored = CodexPlanCredentials(hostID: "urn:uuid:1")
        expect(!stored.usesPlan, "signed out uses nothing")
        stored.apply(
            .init(
                accessToken: "a1", refreshToken: "r1", idToken: "i1", expiresAt: now, earliestRefreshAt: nil,
                scopes: ["openid", "chatgpt.tokens.use.direct"]))
        expect(stored.usesPlan && stored.token?.refreshToken == "r1" && stored.idToken == "i1", "signed in")
        stored.apply(
            .init(accessToken: "a2", refreshToken: nil, idToken: nil, expiresAt: now, earliestRefreshAt: nil, scopes: nil))
        expect(stored.token?.accessToken == "a2" && stored.token?.refreshToken == "r1", "a rotation without one")
        expect(stored.token?.scopes.contains("chatgpt.tokens.use.direct") == true && stored.idToken == "i1",
            "keeps the grant's scopes and the last ID token")
        stored.apply(
            .init(accessToken: "a3", refreshToken: "r2", idToken: nil, expiresAt: now, earliestRefreshAt: nil,
                  scopes: ["openid"]))
        expect(stored.token?.refreshToken == "r2" && !stored.usesPlan, "a replacement and a narrower grant")
        let decoded = try? JSONDecoder().decode(
            CodexPlanCredentials.self, from: (try? JSONEncoder().encode(stored)) ?? Data())
        expect(decoded == stored, "the Keychain record round-trips")
        stored.plan = "plus"
        expect(stored.planTitle == "Plus", "a plan title")
        stored.plan = "something_new"
        expect(stored.planTitle == nil, "an unknown plan shows none")
    }

    static func revocationGoesOnlyToOpenAIsHost() {
        let good = Data(#"{"revocation_endpoint":"https://auth.openai.com/oauth/revoke"}"#.utf8)
        expect(CodexPlanOAuth.revocationEndpoint(in: good)?.absoluteString == "https://auth.openai.com/oauth/revoke",
            "OpenAI's own endpoint")
        let other = Data(#"{"revocation_endpoint":"https://example.com/revoke"}"#.utf8)
        expect(CodexPlanOAuth.revocationEndpoint(in: other) == nil, "another host never gets the token")
        let plain = Data(#"{"revocation_endpoint":"http://auth.openai.com/revoke"}"#.utf8)
        expect(CodexPlanOAuth.revocationEndpoint(in: plain) == nil, "nor plain HTTP")
    }

    // MARK: Streams

    static func fixture(_ name: String) -> Data {
        FileManager.default.contents(atPath: "Tests/codex-plan-fixtures/\(name)") ?? Data()
    }

    /// Fed a line at a time, as the transport feeds it.
    static func decode(_ name: String) -> (events: [AIStreamEvent], decoder: CodexPlanStreamDecoder, error: Error?) {
        var decoder = CodexPlanStreamDecoder(model: "gpt-5.5-codex", now: { now })
        var events: [AIStreamEvent] = []
        do {
            for line in fixture(name).split(separator: 0x0A, omittingEmptySubsequences: false) {
                events += try decoder.feed(Data(line) + Data([0x0A]))
                if decoder.isTerminal { break }
            }
            if !decoder.isTerminal { events += try decoder.finish() }
        } catch {
            return (events, decoder, error)
        }
        return (events, decoder, nil)
    }

    static func textStreamYieldsReasoningAnswerUsageAndLimits() {
        let (events, decoder, error) = decode("responses-text.txt")
        expect(error == nil && decoder.isTerminal, "the stream completes")
        let text = events.compactMap { if case .text(let piece) = $0 { piece } else { nil } }.joined()
        expect(text == "1, 2, 3.", "answer text in order")
        let reasoning = events.compactMap { if case .reasoning(let piece) = $0 { piece } else { nil } }.joined()
        expect(reasoning == "**Counting** the numbers.\n\nDone.", "summary parts separated, never merged")
        expect(events.first == .thinking, "reasoning shows as thinking first")
        let usage = events.compactMap { if case .usage(let usage) = $0 { usage } else { nil } }.last
        expect(usage?.inputTokens == 20 && usage?.cachedInputTokens == 100, "cached tokens count outside input")
        expect(usage?.outputTokens == 40 && usage?.reasoningTokens == 25, "output and reasoning tokens")
        expect(events.last == .finished, "finished last")
        guard case .reasoningReplay(let replay)? = events.first(where: {
            if case .reasoningReplay = $0 { true } else { false }
        }) else {
            return expect(false, "a reasoning model's reply carries its items for the loop")
        }
        expect(replay.route == "codex-plan" && replay.model == "gpt-5.5-codex", "stamped with route and model")
        expect(replay.form == nil && replay.stored == nil, "never kept in a chat's history")
        let item = replay.items.first?.objectValue
        expect(item?["encrypted_content"]?.stringValue == "gAAAA_fixture_one", "the encrypted reasoning kept")
        expect(item?["id"] == nil && item?["status"] == nil, "a stateless item drops its id and status")
        expect(decoder.limits?.primary?.usedPercent == 42 && decoder.limits?.primary?.windowMinutes == 300,
            "a codex.rate_limits event is a snapshot")
        expect(decoder.limits?.secondary?.resetsAt == Date(timeIntervalSince1970: 1_793_500_000), "with resets")
        expect(decoder.limits?.capturedAt == now, "stamped when it came")
    }

    static func toolStreamHandsCallsToTheLoopInOrder() {
        let (events, _, error) = decode("responses-tool-calls.txt")
        expect(error == nil, "the stream completes")
        let calls = events.compactMap { if case .toolCallRequested(let call) = $0 { call } else { nil } }
        expect(
            calls == [
                AIToolCall(id: "call_a", name: "read_file", arguments: #"{"path":"notes.md"}"#),
                AIToolCall(id: "call_b", name: "list_dir", arguments: "{}")
            ], "calls by call id, arguments whole, in the model's order")
        let replay = events.firstIndex { if case .reasoningReplay = $0 { true } else { false } }
        let firstCall = events.firstIndex { if case .toolCallRequested = $0 { true } else { false } }
        expect(replay != nil && firstCall != nil && replay! < firstCall!, "reasoning before the calls it led to")
        expect(events.last == .finished, "finished after the calls")
        expect(!events.contains { if case .text = $0 { true } else { false } }, "no text was invented")
    }

    static func failedStreamCarriesItsCode() {
        let (_, _, error) = decode("responses-failed-limit.txt")
        guard case .failed(let detail, let beforeAnswer)? = error as? CodexPlanStreamDecoder.Failure else {
            return expect(false, "a failed response throws its detail")
        }
        expect(detail.code == "subscription_sharing_usage_limit_exceeded" && beforeAnswer, "the code, before text")
        let failure = CodexPlanFailure.classify(status: nil, detail: detail, limits: nil)
        expect(failure == .usageLimit(resetsAt: nil), "a spent plan, with no reset guessed")
        let spent = CodexPlanLimits(
            primary: .init(usedPercent: 100, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
            secondary: .init(usedPercent: 40, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
            capturedAt: now)
        expect(
            CodexPlanFailure.classify(status: nil, detail: detail, limits: spent)
                == .usageLimit(resetsAt: now.addingTimeInterval(3600)),
            "the spent window's reset, from the reply's own headers")
        var broken = CodexPlanStreamDecoder(model: "m")
        let malformed = (try? broken.feed(Data("data: {nope\n\n".utf8))) == nil
        expect(malformed && broken.isTerminal, "a malformed event ends the stream")
    }

    static func incompleteStreamReportsTheCap() {
        let (events, decoder, error) = decode("responses-incomplete.txt")
        expect(error == nil && decoder.isTerminal, "an incomplete response still ends the stream")
        expect(events.contains(.outputLimit), "the cap is reported for the loop")
        expect(events.last == .finished, "and the reply finishes")
    }

    // MARK: Limits and failures

    static func headersBecomeASnapshot() {
        let headers = [
            "X-Codex-Primary-Used-Percent": "61.5", "x-codex-primary-window-minutes": "300",
            "x-codex-primary-reset-at": "1790003600", "x-codex-secondary-used-percent": "12",
            "x-codex-secondary-window-minutes": "10080", "x-codex-secondary-reset-at": "1790500000",
            "content-type": "text/event-stream"
        ]
        let limits = CodexPlanLimits.parse(headers: headers, now: now)
        expect(limits?.primary?.usedPercent == 61.5 && limits?.primary?.remainingPercent == 39, "primary")
        expect(limits?.primary?.resetsAt == Date(timeIntervalSince1970: 1_790_003_600), "names in any case")
        expect(limits?.secondary?.windowMinutes == 10080, "the weekly window")
        expect(limits?.spentUntil == nil, "nothing spent")
        expect(CodexPlanLimits.parse(headers: ["content-type": "text/event-stream"], now: now) == nil,
            "a reply without the headers leaves the old snapshot alone")
        expect(CodexPlanLimits.parse(headers: ["x-codex-primary-used-percent": "0"], now: now) == nil,
            "an all-zero window is one the server did not fill in")
        expect(CodexPlanLimits.parse(headers: ["x-codex-primary-used-percent": "abc"], now: now) == nil, "junk")
        let spent = CodexPlanLimits.parse(
            headers: [
                "x-codex-primary-used-percent": "100", "x-codex-primary-reset-at": "1790001000",
                "x-codex-secondary-used-percent": "100", "x-codex-secondary-reset-at": "1790009000"
            ], now: now)
        expect(spent?.spentUntil == Date(timeIntervalSince1970: 1_790_009_000), "the later reset lifts both")
        expect(spent?.primary?.remainingPercent == 0, "none left")
        let saved = try? JSONDecoder().decode(
            CodexPlanLimits.self, from: (try? JSONEncoder().encode(limits)) ?? Data())
        expect(saved == limits, "a snapshot round-trips to disk")
    }

    static func failuresMapToClearMessages() {
        func detail(_ text: String) -> CodexPlanFailure.Detail {
            CodexPlanFailure.detail(in: JSONValue(data: Data(text.utf8)))
        }
        let none = CodexPlanFailure.Detail(code: nil, message: nil, param: nil, resetsAt: nil)
        expect(CodexPlanFailure.classify(status: 401, detail: none, limits: nil) == .signInRequired, "401")
        expect(CodexPlanFailure.classify(status: 503, detail: none, limits: nil) == .unavailable, "503")
        expect(CodexPlanFailure.classify(status: 503, detail: none, limits: nil).isTransient, "may pass later")
        let codex = detail(#"{"error":{"type":"usage_limit_reached","resets_at":1790007200,"plan_type":"plus"}}"#)
        expect(
            CodexPlanFailure.classify(status: 429, detail: codex, limits: nil)
                == .usageLimit(resetsAt: Date(timeIntervalSince1970: 1_790_007_200)),
            "Codex's own limit body names its reset")
        let unsupported = detail(
            #"{"error":{"code":"subscription_sharing_unsupported_capability","param":"temperature"}}"#)
        expect(
            CodexPlanFailure.classify(status: 400, detail: unsupported, limits: nil) == .unsupported("temperature"),
            "the refused field is named")
        let notEligible = detail(#"{"error":{"code":"subscription_sharing_user_not_eligible"}}"#)
        expect(CodexPlanFailure.classify(status: 403, detail: notEligible, limits: nil) == .notEligible, "403")
        let invalid = detail(#"{"error":{"code":"subscription_sharing_invalid_user"}}"#)
        expect(CodexPlanFailure.classify(status: 401, detail: invalid, limits: nil) == .signInRequired, "invalid")
        let other = detail(#"{"detail":"Region not supported"}"#)
        expect(CodexPlanFailure.classify(status: 403, detail: other, limits: nil) == .other("Region not supported"),
            "a plain detail body")
        let event = CodexPlanFailure.detail(
            in: .object(["type": .string("error"), "code": .string("subscription_sharing_usage_unavailable")]))
        expect(event.code == "subscription_sharing_usage_unavailable", "an error event's own code")
        let soon = CodexPlanFailure.usageLimit(resetsAt: now.addingTimeInterval(7200)).message(now: now)
        let later = CodexPlanFailure.usageLimit(resetsAt: nil).message(now: now)
        expect(soon.contains("resets") && soon != later, "a known reset is said")
        expect(later.contains("ChatGPT"), "an unknown one points at ChatGPT settings")
        expect(!CodexPlanFailure.usageLimit(resetsAt: nil).isTransient, "a spent limit is not retried")
    }

    // MARK: Request bodies and catalog

    static func requestBodiesStayInsideThePlanRoute() {
        let tool = AITool(
            name: "read_file", description: "Read a file",
            parameters: .object(["type": .string("object")]), origin: "Files")
        let request = AIRequest(
            instructions: "Be brief.",
            messages: [
                AIMessage(role: .system, text: "Context"),
                AIMessage(role: .user, text: "Look", images: [AIImage(data: Data([1]), mimeType: "image/png")]),
                AIMessage(
                    role: .assistant, text: "Reading",
                    toolCalls: [AIToolCall(id: "call_a", name: "read_file", arguments: "")]),
                AIMessage(role: .tool, text: "", toolResult: AIToolResult(callID: "call_a", content: "hi", isError: false))
            ],
            maxOutputTokens: 999, tools: [tool], conversationID: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"),
            temperature: 0.4, outputCap: AIOutputCap(tokens: 100, forced: true))
        let body = CodexPlanRequestBody.make(request, model: "m", effort: "high", reasons: true, replay: nil)
        expect(body["store"] as? Bool == false && body["stream"] as? Bool == true, "stateless and streamed")
        for field in ["temperature", "max_output_tokens", "top_p", "previous_response_id", "metadata", "user"] {
            expect(body[field] == nil, "the route refuses \(field)")
        }
        expect(body["instructions"] as? String == "Be brief.", "instructions at the top")
        expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high", "the chosen effort")
        expect(body["include"] as? [String] == ["reasoning.encrypted_content"], "encrypted reasoning asked for")
        expect(body["prompt_cache_key"] as? String == "6f9619ff-8b86-d011-b42d-00c04fc964ff", "a cache key")
        let input = body["input"] as? [[String: Any]] ?? []
        expect(input.first?["role"] as? String == "developer", "a system message becomes a developer one")
        let user = input[1]["content"] as? [[String: Any]] ?? []
        expect(user.map { $0["type"] as? String } == ["input_text", "input_image"], "text and image parts")
        expect(input[2]["role"] as? String == "assistant", "the assistant's text")
        expect(input[3]["type"] as? String == "function_call" && input[3]["arguments"] as? String == "{}",
            "a call with empty arguments sends an empty object")
        expect(input[4]["type"] as? String == "function_call_output" && input[4]["output"] as? String == "hi",
            "the call's output")
        let tools = body["tools"] as? [[String: Any]] ?? []
        expect(tools.first?["type"] as? String == "function" && tools.first?["name"] as? String == "read_file",
            "tools as Responses functions")
        expect(body["tool_choice"] as? String == "auto", "the model may call")
        let forbidden = CodexPlanRequestBody.make(
            request.limited(nil, forbidsCalls: true), model: "m", effort: nil, reasons: true, replay: nil)
        expect(forbidden["tool_choice"] as? String == "none", "a hand-over round lists tools but calls none")
        expect((forbidden["reasoning"] as? [String: Any])?["effort"] == nil, "no effort leaves the model's own")
        let plain = CodexPlanRequestBody.make(
            AIRequest(messages: [AIMessage(role: .user, text: "Hi")]), model: "m", effort: "default", reasons: false,
            replay: nil)
        expect(plain["reasoning"] == nil && plain["include"] == nil && plain["tools"] == nil, "a plain model")
        expect(plain["instructions"] == nil, "no instructions, no field")
    }

    static func reasoningGoesBackOnlyToItsOwnModelWithinTheTurn() {
        let item = JSONValue.object(["type": .string("reasoning"), "encrypted_content": .string("e")])
        func body(_ replay: AIReasoningReplay, mode: AIConnection.ReasoningReplay? = nil) -> [[String: Any]] {
            let request = AIRequest(messages: [
                AIMessage(role: .user, text: "Q"),
                AIMessage(
                    role: .assistant, text: "",
                    toolCalls: [AIToolCall(id: "c", name: "t", arguments: "{}")], reasoning: replay),
                AIMessage(role: .tool, text: "", toolResult: AIToolResult(callID: "c", content: "r", isError: false))
            ])
            return CodexPlanRequestBody.items(request, model: "m", replay: mode)
        }
        let own = AIReasoningReplay(route: "codex-plan", model: "m", form: nil, text: "s", items: [item])
        let sent = body(own)
        expect(sent[1]["type"] as? String == "reasoning" && sent[2]["type"] as? String == "function_call",
            "this turn's reasoning goes back before its call")
        let another = AIReasoningReplay(route: "codex-plan", model: "other", form: nil, text: "s", items: [item])
        expect(body(another)[1]["type"] as? String == "function_call", "never to another model")
        let elsewhere = AIReasoningReplay(route: "api.openai.com", model: "m", form: nil, text: "s", items: [item])
        expect(body(elsewhere)[1]["type"] as? String == "function_call", "nor from another route")
        let stored = AIReasoningReplay(
            route: "codex-plan", model: "m", form: .reasoning, text: "s", items: [item], isStored: true)
        expect(body(stored)[1]["type"] as? String == "function_call", "an earlier turn's never goes back")
        expect(body(own, mode: .never)[1]["type"] as? String == "function_call", "Never sends none")
    }

    static func catalogsListOnlyShownModelsWithTheirLevels() {
        let models = CodexPlanCatalog.parse(fixture("models.json")) ?? []
        expect(models.map(\.id) == ["gpt-5.5-codex", "gpt-5.5-codex-mini"], "listed models by priority")
        expect(models.first?.efforts == ["low", "medium", "high", "xhigh"], "each model's own levels")
        expect(models.first?.defaultEffort == "high", "and its default")
        let plain = CodexPlanCatalog.parse(Data(#"{"data":[{"id":"gpt-x"},{"id":""}]}"#.utf8))
        expect(plain?.map(\.id) == ["gpt-x"] && plain?.first?.efforts == [], "the public list shape too")
        expect(CodexPlanCatalog.parse(Data("[]".utf8)) == nil, "anything else is no catalog")
        var connection = AIConnection(provider: .codexPlan)
        CodexPlanCatalog.apply(models, to: &connection)
        expect(connection.models == ["gpt-5.5-codex", "gpt-5.5-codex-mini"], "the connection keeps the ids")
        expect(connection.reasoningOptions(for: "gpt-5.5-codex")?.efforts.contains("xhigh") == true,
            "the picker offers the catalog's levels")
        expect(connection.offeredEffort("xhigh", for: "gpt-5.5-codex") == "xhigh", "a listed level is sent")
        expect(connection.offeredEffort("xhigh", for: "gpt-5.5-codex-mini") == nil, "an unlisted one is not")
        expect(connection.reasoningOptions(for: "gpt-5.5-codex")?.resolvedEffort(nil) == "high", "defaults")
        expect(!connection.takesThinkingField, "the plan is never sent a gateway's thinking field")
        expect(connection.title == "Codex (ChatGPT)" && connection.baseURL == "https://api.openai.com/v1", "title")
        let decoded = try? JSONDecoder().decode(
            AIConnection.self, from: (try? JSONEncoder().encode(connection)) ?? Data())
        expect(decoded?.provider == .codexPlan, "the kind is saved with the connection")
    }
}
