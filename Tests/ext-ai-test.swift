import Foundation
import Synchronization

/// Only `RenderNode.arguments(from:)` reaches for the runtime, and this harness never runs JS.
enum ExtensionRuntime {
    static func jsonArray(from json: String) -> [Any] { [] }
}

/// A provider that plays a script: events, pauses, a failure, or a wait that only a cancel ends.
final class ScriptedProvider: AIProvider {
    enum Step: Sendable {
        case event(AIStreamEvent)
        case pause(milliseconds: Int)
        case fail(String)
        case hang
    }

    let script: @Sendable (AIRequest) -> [Step]
    let terminated = Mutex(false)
    let received = Mutex<[AIRequest]>([])

    init(_ steps: [Step]) {
        script = { _ in steps }
    }

    /// Answers by what was asked, the way a route refusing a parameter does.
    init(script: @escaping @Sendable (AIRequest) -> [Step]) {
        self.script = script
    }

    var wasTerminated: Bool { terminated.withLock { $0 } }
    var requests: [AIRequest] { received.withLock { $0 } }

    func stream(_ request: AIRequest) -> AIProviderStream {
        received.withLock { $0.append(request) }
        let steps = script(request)
        return AsyncThrowingStream { continuation in
            let task = Task { [steps] in
                for step in steps {
                    switch step {
                    case .event(let event):
                        continuation.yield(event)
                    case .pause(let milliseconds):
                        try? await Task.sleep(for: .milliseconds(milliseconds))
                    case .fail(let message):
                        continuation.finish(throwing: AIProviderError.responseFailed(message))
                        return
                    case .hang:
                        try? await Task.sleep(for: .seconds(60))
                    }
                    if Task.isCancelled { return }
                }
                continuation.finish()
            }
            continuation.onTermination = { [self] _ in
                terminated.withLock { $0 = true }
                task.cancel()
            }
        }
    }
}

final class Owner {}

@main
@MainActor
struct ExtensionAITests {
    static var failures = 0
    static var passes = 0
    /// Kept alive: a freed owner's address, and so its identifier, can come back for the next one.
    static let owners = (Owner(), Owner())
    static let owner = ObjectIdentifier(owners.0)
    static let otherOwner = ObjectIdentifier(owners.1)

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() async {
        gatesApplyInOrder()
        promptsAreBounded()
        theRequestIsThePromptAlone()
        onlyADeletedConnectionDangles()
        refusalsExplainThemselves()
        creativityBecomesTemperature()
        namedModelsFindTheirVendor()
        theRateLimitSlides()
        await deltasCoalesceUntilRead()
        await aReadWaitsForTheNextDelta()
        await onlyAnswerTextReachesAReader()
        await textBeforeAFailureArrivesFirst()
        await cancellingEndsTheProvider()
        await streamsBelongToTheirOwner()
        await aCancelledReaderCancelsTheStream()
        await aRefusedTemperatureIsAskedAgainWithout()
        await aCommandNobodyOpenedNeverAsks()
        await aMissingModelIsReportedBeforeAsking()
        await concurrentAsksShareOneQuestion()
        await aDismissedQuestionKeepsNothing()
        await onlyAChosenButtonIsKept()
        await aSwitchTurnedOffDuringTheQuestionWins()
        await aCommandLeftDuringTheQuestionStartsNothing()
        await aReadChecksTheGatesAgain()
        await turningTheSwitchOffEndsEveryAnswer()
        await leavingACommandEndsOnlyItsAnswers()
        await theLimitCountsOnlyRoutedAsks()
        await aNamedModelIsUsedOnlyWhenAllowed()
        await creativityReachesTheRoute()
        aDanglingPickFallsBackToChat()
        settingsRoundTrip()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Policy

    static func gatesApplyInOrder() {
        func access(_ featureOn: Bool, _ aiOn: Bool, _ actingForUser: Bool, _ grant: Bool?) -> ExtensionAIAccess {
            ExtensionAIPolicy.access(featureOn: featureOn, aiOn: aiOn, actingForUser: actingForUser, grant: grant)
        }
        expect(access(false, true, true, true) == .refused(.featureOff), "the switch comes first")
        expect(access(false, false, false, false) == .refused(.featureOff), "the switch beats every gate")
        expect(access(true, false, true, true) == .refused(.aiOff), "AI off is refused next")
        expect(access(true, false, false, true) == .refused(.aiOff), "AI off beats an unattended run")
        expect(access(true, true, false, true) == .refused(.unattended), "an unattended run beats an allowance")
        expect(access(true, true, false, nil) == .refused(.unattended), "an unattended run never asks")
        expect(access(true, true, true, false) == .refused(.denied), "a refusal is kept")
        expect(access(true, true, true, nil) == .ask, "a first use asks")
        expect(access(true, true, true, true) == .allowed, "an allowance is kept")
    }

    static func promptsAreBounded() {
        func refusal(_ raw: String) -> ExtensionAIRefusal? {
            do {
                _ = try ExtensionAIPolicy.prompt(from: raw)
                return nil
            } catch {
                return error
            }
        }
        expect(refusal("") == .emptyPrompt, "an empty prompt is refused")
        expect(refusal(" \n\t ") == .emptyPrompt, "a whitespace prompt is refused")
        let limit = ExtensionAIPolicy.maxPromptBytes
        expect(limit == 262_144, "the cap is 256 KB")
        expect(refusal(String(repeating: "a", count: limit)) == nil, "a prompt at the cap is accepted")
        expect(
            refusal(String(repeating: "a", count: limit + 1)) == .promptTooLong(kilobytes: 257),
            "one byte over is refused, rounded up to whole kilobytes")
        expect(refusal(String(repeating: "€", count: limit / 3)) == nil, "3-byte characters up to the cap pass")
        expect(
            refusal(String(repeating: "€", count: limit / 3 + 1)) == .promptTooLong(kilobytes: 257),
            "the cap counts UTF-8 bytes, not characters")
        expect((try? ExtensionAIPolicy.prompt(from: " hi ")) == " hi ", "an accepted prompt is unchanged")
    }

    static func theRequestIsThePromptAlone() {
        let request = ExtensionAIPolicy.request(prompt: "Name three colours.")
        expect(request.instructions == nil, "no preamble or system prompt")
        expect(
            request.messages.count == 1 && request.messages.first?.role == .user
                && request.messages.first?.text == "Name three colours.",
            "one user message, the prompt")
        expect(request.maxOutputTokens == 4_096, "chat's output limit")
        expect(request.tools.isEmpty && !request.webSearch, "no tools and no web search")
        expect(request.conversationID == nil, "no conversation")
        expect(request.temperature == nil, "and the route's own temperature")
    }

    static func onlyADeletedConnectionDangles() {
        let connection = AIConnection(provider: .openAI, models: ["gpt"])
        let connections = [connection]
        expect(
            ExtensionAIPolicy.isDangling(
                .api(connection: UUID(), model: "gpt", effort: nil), connections: connections),
            "a deleted connection dangles")
        expect(
            ExtensionAIPolicy.isDangling(
                .api(connection: connection.id, model: "gone", effort: nil), connections: connections),
            "a deleted model dangles")
        expect(
            !ExtensionAIPolicy.isDangling(
                .api(connection: connection.id, model: "gpt", effort: "high"), connections: connections),
            "a present connection and model do not")
        expect(!ExtensionAIPolicy.isDangling(.appleIntelligence, connections: []), "on-device never dangles")
        expect(
            !ExtensionAIPolicy.isDangling(.claude(model: "opus", effort: nil), connections: []),
            "an installed route is reported by the factory, never rerouted")
    }

    static func refusalsExplainThemselves() {
        let all: [ExtensionAIRefusal] = [
            .featureOff, .aiOff, .unattended, .denied, .unanswered, .noModel, .emptyPrompt,
            .promptTooLong(kilobytes: 300), .rateLimited(seconds: 42)
        ]
        let messages = all.compactMap(\.errorDescription)
        expect(messages.count == all.count && messages.allSatisfy { !$0.isEmpty }, "every refusal has a message")
        expect(Set(messages).count == all.count, "no two refusals read alike")
        expect(
            ExtensionAIRefusal.promptTooLong(kilobytes: 300).errorDescription?.contains("300") == true
                && ExtensionAIRefusal.promptTooLong(kilobytes: 300).errorDescription?.contains("256") == true,
            "the size refusal names the size and the cap")
        expect(
            ExtensionAIRefusal.rateLimited(seconds: 42).errorDescription?.contains("42") == true,
            "the rate refusal names the wait")
    }

    static func creativityBecomesTemperature() {
        let levels: [(RenderValue?, Double?)] = [
            (.string("none"), 0), (.string("low"), 0.4), (.string("medium"), 0.7), (.string("high"), 1),
            (.string("maximum"), 1.5), (.string("Maximum"), 1.5), (.number(1.2), 1.2), (.number(-1), 0),
            (.number(7), 2), (.number(.nan), nil), (.string("wild"), nil), (.bool(true), nil), (nil, nil)
        ]
        for (creativity, temperature) in levels {
            expect(
                ExtensionAIPolicy.temperature(creativity: creativity, brand: .openAI) == temperature
                    && ExtensionAIPolicy.temperature(creativity: creativity, brand: nil) == temperature,
                "creativity \(String(describing: creativity)) is \(String(describing: temperature))")
        }
        expect(
            ExtensionAIPolicy.temperature(creativity: .string("none"), brand: .gemini) == nil
                && ExtensionAIPolicy.temperature(creativity: .number(1.5), brand: .gemini) == nil,
            "a Gemini model keeps its default, below which Gemini 3 loops")
        let request = ExtensionAIPolicy.request(prompt: "p", temperature: 0.4)
        expect(request.temperature == 0.4, "the request carries it")
        let refusal = AIProviderError.responseFailed(
            "The provider rejected the model or request (HTTP 400).\n\nUnsupported value: 'temperature' "
                + "does not support 0.4 with this model. Only the default (1) value is supported.")
        let retry = ExtensionAIPolicy.withoutTemperature(request, after: refusal)
        expect(
            retry?.temperature == nil && retry?.messages == request.messages
                && retry?.maxOutputTokens == request.maxOutputTokens && retry?.instructions == nil,
            "a refusal naming temperature asks the same turn again without it")
        expect(
            ExtensionAIPolicy.withoutTemperature(request, after: AIProviderError.responseFailed("Overloaded."))
                == nil,
            "any other failure is not retried")
        expect(
            ExtensionAIPolicy.withoutTemperature(ExtensionAIPolicy.request(prompt: "p"), after: refusal) == nil,
            "a turn sent without temperature is never retried")
    }

    static func namedModelsFindTheirVendor() {
        let anthropic = AIConnection(
            provider: .anthropic, models: ["claude-opus-4-1", "claude-sonnet-4-5", "claude-haiku-4-5"])
        let openAI = AIConnection(provider: .openAI, models: ["gpt-5", "gpt-5-mini", "gpt-4o"])
        let gemini = AIConnection(provider: .gemini, models: ["gemini-2.5-pro", "gemini-2.5-flash"])
        let router = AIConnection(
            provider: .openRouter,
            models: [
                "anthropic/claude-haiku-4.5", "google/gemini-2.5-flash", "x-ai/grok-4", "mistralai/mistral-large"
            ])
        let local = AIConnection(
            provider: .openAICompatible, baseURL: "http://localhost:11434/v1",
            models: ["llama3.1", "deepseek-r1:8b"])
        let all = [router, anthropic, openAI, gemini, local]
        func route(
            _ requested: String, offered: [AIConnection]? = nil,
            fallback: AIModelSelection? = .appleIntelligence
        ) -> AIModelSelection? {
            ExtensionAIModelRoute.selection(for: requested, fallback: fallback, offered: offered ?? all)
        }
        func pick(_ connection: AIConnection, _ model: String) -> AIModelSelection {
            .api(connection: connection.id, model: model, effort: nil)
        }
        expect(
            ExtensionAIModelRoute.tokens(of: "Anthropic_Claude_Haiku_4.5")
                == ["anthropic", "claude", "haiku", "4", "5"]
                && ExtensionAIModelRoute.tokens(of: "gpt-4o") == ["gpt", "4", "o"],
            "names split into runs of letters or digits")
        expect(
            route("Anthropic_Claude_Haiku_4.5") == pick(anthropic, "claude-haiku-4-5"),
            "an Anthropic key reaches the Anthropic connection before a router, at its closest model")
        expect(
            route("anthropic-claude-opus-5") == pick(anthropic, "claude-opus-4-1"),
            "a Raycast value names its vendor and tier too")
        expect(route("OpenAI_GPT-5_mini") == pick(openAI, "gpt-5-mini"), "a tier word decides")
        expect(route("OpenAI_GPT-4o") == pick(openAI, "gpt-4o"), "an exact family wins")
        expect(
            route("OpenAI_GPT-6_Luna") == pick(openAI, "gpt-5"),
            "with nothing closer, the shortest name answers, then the first")
        expect(route("Google_Gemini_3.8_Flash") == pick(gemini, "gemini-2.5-flash"), "Gemini reaches Gemini")
        expect(
            route("Google_Gemini_3.8_Flash", offered: [router, openAI]) == pick(router, "google/gemini-2.5-flash"),
            "or OpenRouter when there is no Gemini connection")
        expect(route("xAI_Grok-4.7") == pick(router, "x-ai/grok-4"), "xAI goes through the router")
        expect(route("Mistral_Large") == pick(router, "mistralai/mistral-large"), "so does Mistral")
        expect(route("DeepSeek_R1") == pick(local, "deepseek-r1:8b"), "a gateway's model answers for its vendor")
        expect(route("Perplexity_Sonar") == nil, "a vendor nobody offers leaves the extension model")
        expect(
            route("Vercel_Inkling") == nil && route("tinycast") == nil && route("") == nil,
            "and so does a name with no vendor")
        expect(
            route("Anthropic_Claude_Opus_5", fallback: pick(anthropic, "claude-haiku-4-5")) == nil,
            "an extension model of the named vendor is never swapped, even for a closer one")
        expect(
            route("Anthropic_Claude_Haiku_4.5", fallback: .claude(model: "sonnet", effort: nil)) == nil
                && route("OpenAI_GPT-4o", fallback: .codex(model: "gpt-5", effort: "high")) == nil
                && route("Anthropic_Claude_Haiku_4.5", fallback: pick(router, "anthropic/claude-haiku-4.5"))
                    == nil,
            "nor is Claude's CLI, Codex or a router's model of that vendor")
        expect(
            route("Anthropic_Claude_Haiku_4.5", fallback: pick(openAI, "gpt-5")) == pick(anthropic, "claude-haiku-4-5")
                && route("Anthropic_Claude_Haiku_4.5", fallback: nil) == pick(anthropic, "claude-haiku-4-5"),
            "another vendor's extension model is")
    }

    // MARK: - Rate limit

    static func theRateLimitSlides() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var limit = ExtensionAIRateLimit()
        for second in 0..<10 {
            expect(limit.admit("a", at: start + Double(second)) == nil, "request \(second + 1) is admitted")
        }
        let wait = limit.admit("a", at: start + 10)
        expect(wait.map { abs($0 - 50) < 0.001 } == true, "the 11th waits until the first leaves the minute")
        expect(limit.admit("b", at: start + 10) == nil, "another extension has its own window")
        expect(limit.admit("a", at: start + 60) == nil, "a minute after the first, one more is admitted")

        var hourly = ExtensionAIRateLimit()
        for index in 0..<100 {
            _ = hourly.admit("a", at: start + Double(index) * 30)
        }
        let refused = hourly.admit("a", at: start + 3_000)
        expect(refused.map { abs($0 - 600) < 0.001 } == true, "the 101st in an hour is refused even spread out")
        expect(hourly.admit("a", at: start + 3_600) == nil, "stamps an hour old are pruned")
    }

    // MARK: - Bridge

    static func settle(_ milliseconds: Int = 40) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    static func read(
        _ bridge: ExtensionAIBridge, _ id: Int, owner: ObjectIdentifier
    ) async -> Result<String?, any Error> {
        do {
            return .success(try await bridge.read(id, owner: owner))
        } catch {
            return .failure(error)
        }
    }

    static func deltasCoalesceUntilRead() async {
        let bridge = ExtensionAIBridge()
        let id = bridge.start(
            ExtensionAIPolicy.request(prompt: "p"),
            on: ScriptedProvider([.event(.text("Hel")), .event(.text("lo"))]), owner: owner)
        await settle()
        let first = await read(bridge, id, owner: owner)
        let second = await read(bridge, id, owner: owner)
        expect((try? first.get()) == "Hello", "deltas that arrived before a read come as one chunk")
        expect((try? second.get()) == .some(nil), "then the end")
        expect(bridge.isIdle, "an ended answer is released")
    }

    static func aReadWaitsForTheNextDelta() async {
        let bridge = ExtensionAIBridge()
        let id = bridge.start(
            ExtensionAIPolicy.request(prompt: "p"),
            on: ScriptedProvider([.pause(milliseconds: 50), .event(.text("a")), .pause(milliseconds: 30)]),
            owner: owner)
        let first = await read(bridge, id, owner: owner)
        expect((try? first.get()) == "a", "a read waits for the next delta")
        let last = await read(bridge, id, owner: owner)
        expect((try? last.get()) == .some(nil), "and the next waits for the end")
        expect(bridge.isIdle, "nothing is left behind")
    }

    static func onlyAnswerTextReachesAReader() async {
        let bridge = ExtensionAIBridge()
        let provider = ScriptedProvider([
            .event(.thinking), .event(.reasoning("hmm")), .event(.searching("q")),
            .event(.usage(AIUsage(inputTokens: 1, outputTokens: 2))), .event(.text("")),
            .event(.text("answer")), .event(.finished)
        ])
        let id = bridge.start(ExtensionAIPolicy.request(prompt: "p"), on: provider, owner: owner)
        await settle()
        let text = await read(bridge, id, owner: owner)
        let end = await read(bridge, id, owner: owner)
        expect((try? text.get()) == "answer", "reasoning, thinking, search and usage are dropped")
        expect((try? end.get()) == .some(nil), "and the answer ends")
    }

    static func textBeforeAFailureArrivesFirst() async {
        let bridge = ExtensionAIBridge()
        let id = bridge.start(
            ExtensionAIPolicy.request(prompt: "p"),
            on: ScriptedProvider([.event(.text("partial")), .fail("The model went away.")]), owner: owner)
        await settle()
        let text = await read(bridge, id, owner: owner)
        let failure = await read(bridge, id, owner: owner)
        expect((try? text.get()) == "partial", "the unread text comes first")
        if case .failure(let error) = failure {
            expect(error.localizedDescription == "The model went away.", "then the provider's own message")
        } else {
            expect(false, "a failed answer throws on the read after its text")
        }
        expect(bridge.isIdle, "a failed answer is released")
    }

    static func cancellingEndsTheProvider() async {
        let bridge = ExtensionAIBridge()
        let provider = ScriptedProvider([.hang])
        let id = bridge.start(ExtensionAIPolicy.request(prompt: "p"), on: provider, owner: owner)
        let reader = Task { await read(bridge, id, owner: owner) }
        await settle()
        bridge.cancel(id)
        let result = await reader.value
        await settle()
        if case .failure(let error) = result {
            expect(error is CancellationError, "a waiting read throws CancellationError")
        } else {
            expect(false, "a cancelled answer does not resolve")
        }
        expect(provider.wasTerminated, "the provider's stream is terminated")
        expect(bridge.isIdle, "the entry is gone")
    }

    static func streamsBelongToTheirOwner() async {
        let bridge = ExtensionAIBridge()
        let first = owner
        let second = otherOwner
        let mine = ScriptedProvider([.hang])
        let theirs = ScriptedProvider([.hang])
        let id = bridge.start(ExtensionAIPolicy.request(prompt: "p"), on: mine, owner: first)
        let other = bridge.start(ExtensionAIPolicy.request(prompt: "p"), on: theirs, owner: second)

        if case .failure(let error) = await read(bridge, id, owner: second) {
            expect(error is ExtensionAIBridge.BridgeError, "another owner's read is refused")
        } else {
            expect(false, "another owner's read is refused")
        }
        if case .failure = await read(bridge, 999, owner: first) {
            expect(true, "an unknown answer is refused")
        } else {
            expect(false, "an unknown answer is refused")
        }
        let waiting = Task { await read(bridge, id, owner: first) }
        await settle()
        if case .failure = await read(bridge, id, owner: first) {
            expect(true, "a second concurrent read is refused")
        } else {
            expect(false, "a second concurrent read is refused")
        }
        bridge.cancel(id, owner: second)
        expect(!bridge.isIdle, "another owner's cancel reaches nothing")

        bridge.cancelAll(owner: first)
        _ = await waiting.value
        await settle()
        expect(mine.wasTerminated && !theirs.wasTerminated, "cancelAll(owner:) touches only that owner")
        bridge.cancelAll()
        await settle()
        expect(theirs.wasTerminated && bridge.isIdle, "cancelAll() ends every answer")
        _ = other
    }

    static func aCancelledReaderCancelsTheStream() async {
        let bridge = ExtensionAIBridge()
        let provider = ScriptedProvider([.hang])
        let id = bridge.start(ExtensionAIPolicy.request(prompt: "p"), on: provider, owner: owner)
        let reader = Task { await read(bridge, id, owner: owner) }
        await settle()
        reader.cancel()
        let result = await reader.value
        await settle()
        if case .failure(let error) = result {
            expect(error is CancellationError, "the cancelled read throws CancellationError")
        } else {
            expect(false, "the cancelled read throws")
        }
        expect(provider.wasTerminated && bridge.isIdle, "cancelling the reading task ends the stream")
    }

    static func aRefusedTemperatureIsAskedAgainWithout() async {
        let bridge = ExtensionAIBridge()
        let refusing = ScriptedProvider { request in
            request.temperature == nil
                ? [.event(.text("ok"))]
                : [.fail("Unsupported value: 'temperature' does not support 0.4 with this model.")]
        }
        let id = bridge.start(
            ExtensionAIPolicy.request(prompt: "p", temperature: 0.4), on: refusing, owner: owner)
        await settle()
        let text = await read(bridge, id, owner: owner)
        let end = await read(bridge, id, owner: owner)
        expect(
            (try? text.get()) == "ok" && (try? end.get()) == .some(nil),
            "a route refusing temperature answers when asked without it")
        expect(refusing.requests.map(\.temperature) == [0.4, nil], "asked twice, the second time without it")

        let late = ScriptedProvider([.event(.text("partial")), .fail("temperature drifted")])
        let lateID = bridge.start(ExtensionAIPolicy.request(prompt: "p", temperature: 0.4), on: late, owner: owner)
        await settle()
        _ = await read(bridge, lateID, owner: owner)
        let failure = await read(bridge, lateID, owner: owner)
        if case .failure = failure {
            expect(late.requests.count == 1, "a failure after text is never asked again")
        } else {
            expect(false, "a failure after text is reported")
        }

        let always = ScriptedProvider([.fail("temperature is not supported")])
        let alwaysID = bridge.start(ExtensionAIPolicy.request(prompt: "p", temperature: 1), on: always, owner: owner)
        await settle()
        if case .failure(let error) = await read(bridge, alwaysID, owner: owner) {
            expect(
                always.requests.count == 2 && error.localizedDescription == "temperature is not supported",
                "the second ask is the last, and its failure is the route's own")
        } else {
            expect(false, "a route that refuses twice fails")
        }
        expect(bridge.isIdle, "nothing is left behind")
    }

    // MARK: - Gate

    /// The gate on scratch defaults with AI on and one API model; the test plays the dialog.
    @MainActor
    final class Gate {
        enum Reply {
            case now(Bool?)
            case held
        }

        let suite = "ext-ai-test-gate-\(UUID().uuidString)"
        let defaults: UserDefaults
        let aiSettings: AISettingsStore
        var aiOn = true
        var reply = Reply.now(true)
        var routeFails = false
        var refused: Set<AIModelSelection> = []
        var provider = ScriptedProvider([.event(.text("answer"))])
        private(set) var asked: [String] = []
        private(set) var made = 0
        private(set) var routes: [AIModelSelection] = []
        private var held: [CheckedContinuation<Bool?, Never>] = []

        private(set) lazy var gate = ExtensionAIGate(
            defaults: defaults, aiSettings: aiSettings, aiEnabled: { [unowned self] in aiOn },
            ask: { [unowned self] name in
                asked.append(name)
                switch reply {
                case .now(let answer): return answer
                case .held: return await withCheckedContinuation { held.append($0) }
                }
            },
            makeProvider: { [unowned self] selection in
                if routeFails || refused.contains(selection) {
                    throw AIProviderError.unavailable("The route is off.")
                }
                made += 1
                routes.append(selection)
                return provider
            })

        init(model: Bool = true, featureOn: Bool = true) {
            defaults = UserDefaults(suiteName: suite) ?? .standard
            aiSettings = AISettingsStore(defaults: defaults)
            if model { aiSettings.save(AIConnection(provider: .openAI, models: ["gpt"])) }
            gate.setEnabled(featureOn)
        }

        var isAsking: Bool { !held.isEmpty }

        func answer(_ answer: Bool?) {
            let waiting = held
            held = []
            for question in waiting { question.resume(returning: answer) }
        }

        func close() {
            gate.setEnabled(false)
            defaults.removePersistentDomain(forName: suite)
        }

        func start(
            _ name: String = "ext", prompt: String = "p", model: String? = nil,
            creativity: RenderValue? = nil, actingForUser: Bool = true,
            owner: ObjectIdentifier = ExtensionAITests.owner
        ) async -> Result<Int, any Error> {
            var ask: [String: RenderValue] = ["prompt": .string(prompt)]
            ask["model"] = model.map(RenderValue.string)
            ask["creativity"] = creativity
            do {
                let id = try await gate.perform(
                    method: "start", arguments: [.object(ask)],
                    extensionName: name, actingForUser: actingForUser, owner: owner)
                return .success(id as? Int ?? -1)
            } catch {
                return .failure(error)
            }
        }

        func read(_ id: Int, _ name: String = "ext") async -> Result<String?, any Error> {
            do {
                let chunk = try await gate.perform(
                    method: "read", arguments: [.number(Double(id))], extensionName: name,
                    actingForUser: true, owner: ExtensionAITests.owner)
                return .success(chunk as? String)
            } catch {
                return .failure(error)
            }
        }
    }

    static func refusal<Value>(_ result: Result<Value, any Error>) -> ExtensionAIRefusal? {
        guard case .failure(let error) = result else { return nil }
        return error as? ExtensionAIRefusal
    }

    static func aCommandNobodyOpenedNeverAsks() async {
        let fixture = Gate()
        defer { fixture.close() }
        let result = await fixture.start(actingForUser: false)
        expect(refusal(result) == .unattended, "a run the user didn't open is refused")
        expect(fixture.asked.isEmpty && fixture.made == 0, "before any question or route")
        expect(fixture.gate.settings.grants.isEmpty, "and nothing is recorded for it")
        expect(fixture.gate.canAccess(extensionName: "ext"), "a command the user opens may still ask")
    }

    static func aMissingModelIsReportedBeforeAsking() async {
        let fixture = Gate(model: false)
        defer { fixture.close() }
        let result = await fixture.start()
        expect(refusal(result) == .noModel, "no model is refused")
        expect(fixture.asked.isEmpty, "without asking a question it can't act on")
        expect(!fixture.gate.canAccess(extensionName: "ext"), "and canAccess reports it")
    }

    static func concurrentAsksShareOneQuestion() async {
        let fixture = Gate()
        defer { fixture.close() }
        fixture.reply = .held
        async let first = fixture.start()
        async let second = fixture.start()
        await settle()
        expect(fixture.asked == ["ext"] && fixture.isAsking, "two asks raise one question")
        fixture.answer(true)
        let (one, two) = await (first, second)
        expect(
            (try? one.get()).map { $0 > 0 } == true && (try? two.get()).map { $0 > 0 } == true
                && (try? one.get()) != (try? two.get()),
            "an Allow starts both answers")
        expect(fixture.gate.settings.grants == ["ext": true] && fixture.made == 2, "and is kept")
        let third = await fixture.start()
        expect(refusal(third) == nil && fixture.asked.count == 1, "the next ask isn't asked")
    }

    static func aDismissedQuestionKeepsNothing() async {
        let fixture = Gate()
        defer { fixture.close() }
        fixture.reply = .now(nil)
        let result = await fixture.start()
        expect(refusal(result) == .unanswered, "a dismissed or busy dialog refuses once")
        expect(fixture.gate.settings.grants.isEmpty && fixture.made == 0, "and records no answer")
        _ = await fixture.start()
        expect(fixture.asked.count == 2, "so the next ask asks again")
        expect(fixture.gate.canAccess(extensionName: "ext"), "and canAccess still reports a question")
    }

    static func onlyAChosenButtonIsKept() async {
        let fixture = Gate()
        defer { fixture.close() }
        fixture.reply = .now(false)
        let first = await fixture.start()
        expect(refusal(first) == .denied, "Don't Allow refuses")
        expect(fixture.gate.settings.grants == ["ext": false], "and is kept")
        let second = await fixture.start()
        expect(refusal(second) == .denied && fixture.asked.count == 1, "without asking again")
        expect(!fixture.gate.canAccess(extensionName: "ext"), "canAccess reports the refusal")
    }

    static func aSwitchTurnedOffDuringTheQuestionWins() async {
        let fixture = Gate()
        defer { fixture.close() }
        fixture.reply = .held
        async let asking = fixture.start()
        await settle()
        fixture.aiOn = false
        fixture.answer(true)
        let result = await asking
        expect(refusal(result) == .aiOff, "the gates are checked again after the answer")
        expect(fixture.gate.settings.grants == ["ext": true], "the answer itself is kept")
        expect(fixture.made == 0 && fixture.gate.isIdle, "and no route is made")
    }

    static func aCommandLeftDuringTheQuestionStartsNothing() async {
        let fixture = Gate()
        defer { fixture.close() }
        fixture.reply = .held
        let asking = Task { await fixture.start() }
        await settle()
        asking.cancel()
        fixture.answer(true)
        let result = await asking.value
        if case .failure(let error) = result {
            expect(error is CancellationError, "a cancelled ask throws CancellationError")
        } else {
            expect(false, "a cancelled ask starts nothing")
        }
        expect(fixture.made == 0 && fixture.gate.isIdle, "no route is made")
    }

    static func aReadChecksTheGatesAgain() async {
        let fixture = Gate()
        defer { fixture.close() }
        fixture.provider = ScriptedProvider([.hang])
        guard let id = try? await fixture.start().get() else {
            expect(false, "an allowed ask starts")
            return
        }
        fixture.aiOn = false
        let refused = await fixture.read(id)
        expect(refusal(refused) == .aiOff, "a read after AI is turned off is refused")
        await settle()
        expect(fixture.provider.wasTerminated && fixture.gate.isIdle, "and ends the answer")

        fixture.aiOn = true
        fixture.provider = ScriptedProvider([.hang])
        guard let next = try? await fixture.start().get() else {
            expect(false, "a second ask starts")
            return
        }
        fixture.gate.settings.setGrant(false, for: "ext")
        let withdrawn = await fixture.read(next)
        expect(refusal(withdrawn) == .denied, "an allowance withdrawn in Settings ends it")
        await settle()
        expect(fixture.provider.wasTerminated && fixture.gate.isIdle, "at its next read")
    }

    static func turningTheSwitchOffEndsEveryAnswer() async {
        let fixture = Gate()
        defer { fixture.close() }
        fixture.provider = ScriptedProvider([.hang])
        _ = await fixture.start("a")
        _ = await fixture.start("b", owner: otherOwner)
        expect(!fixture.gate.isIdle, "two answers are in flight")
        fixture.gate.setEnabled(false)
        await settle()
        expect(fixture.provider.wasTerminated && fixture.gate.isIdle, "the switch ends them all")
        expect(!fixture.gate.settings.isEnabled, "and stays off")
    }

    static func leavingACommandEndsOnlyItsAnswers() async {
        let fixture = Gate()
        defer { fixture.close() }
        let mine = ScriptedProvider([.hang])
        let theirs = ScriptedProvider([.hang])
        fixture.provider = mine
        _ = await fixture.start()
        fixture.provider = theirs
        _ = await fixture.start(owner: otherOwner)
        fixture.gate.sessionEnded(owner: owner)
        await settle()
        expect(mine.wasTerminated && !theirs.wasTerminated, "a session's end cancels only its answers")
        expect(!fixture.gate.isIdle, "the other command's answer runs on")
    }

    static func theLimitCountsOnlyRoutedAsks() async {
        let fixture = Gate()
        defer { fixture.close() }
        for _ in 0..<4 {
            _ = await fixture.start(actingForUser: false)
            _ = await fixture.start(prompt: " ")
        }
        fixture.routeFails = true
        for _ in 0..<4 {
            _ = await fixture.start()
        }
        fixture.routeFails = false
        var admitted = 0
        for _ in 0..<10 where (try? await fixture.start().get()) != nil {
            admitted += 1
        }
        expect(admitted == 10, "twelve refused asks cost nothing: ten more are admitted")
        let limited = await fixture.start()
        if case .rateLimited(let seconds)? = refusal(limited) {
            expect(seconds > 0 && seconds <= 60, "the eleventh waits for the minute")
        } else {
            expect(false, "the eleventh routed ask is limited")
        }
        expect(fixture.made == 11, "a limited ask was routed before the limit refused it")
        let other = await fixture.start("other")
        expect(refusal(other) == nil, "another extension has its own limit")
    }

    static func aNamedModelIsUsedOnlyWhenAllowed() async {
        let fixture = Gate()
        defer { fixture.close() }
        let claude = AIConnection(provider: .anthropic, models: ["claude-sonnet-4-5", "claude-haiku-4-5"])
        fixture.aiSettings.save(claude)
        let haiku = AIModelSelection.api(connection: claude.id, model: "claude-haiku-4-5", effort: nil)
        let chat = fixture.gate.selection()
        _ = await fixture.start(model: "Anthropic_Claude_Haiku_4.5")
        expect(
            !fixture.gate.settings.honorsModels && fixture.routes.count == 1 && fixture.routes.first == chat,
            "the switch starts off, and off a named model changes nothing")

        fixture.gate.settings.honorsModels = true
        _ = await fixture.start(model: "Anthropic_Claude_Haiku_4.5")
        expect(fixture.routes.last == haiku, "on, an Anthropic name reaches the Anthropic connection")
        _ = await fixture.start(model: "Perplexity_Sonar")
        expect(fixture.routes.last == chat, "a vendor nobody offers falls back silently")

        fixture.refused = [haiku]
        let fallback = await fixture.start(model: "Anthropic_Claude_Haiku_4.5")
        expect(
            refusal(fallback) == nil && fixture.routes.last == chat,
            "and so does a named route that can't be built")
        fixture.refused = []

        fixture.aiSettings.setModel(
            "claude-haiku-4-5", shown: false, in: .api(claude.id), available: claude.models)
        _ = await fixture.start(model: "Anthropic_Claude_Haiku_4.5")
        expect(
            fixture.routes.last == .api(connection: claude.id, model: "claude-sonnet-4-5", effort: nil),
            "a model hidden from the picker is not offered")
        fixture.aiSettings.setRoute(.api(claude.id), enabled: false)
        _ = await fixture.start(model: "Anthropic_Claude_Haiku_4.5")
        expect(fixture.routes.last == chat, "nor is a connection switched off")
        expect(fixture.asked == ["ext"], "one question covers every route the extension reaches")
    }

    static func creativityReachesTheRoute() async {
        let fixture = Gate()
        defer { fixture.close() }
        _ = await fixture.start(creativity: .string("high"))
        _ = await fixture.start(creativity: .number(5))
        _ = await fixture.start()
        let gemini = AIConnection(provider: .gemini, models: ["gemini-3.8-flash"])
        fixture.aiSettings.save(gemini)
        fixture.gate.settings.honorsModels = true
        _ = await fixture.start(model: "Google_Gemini_3.8_Flash", creativity: .string("none"))
        await settle()
        expect(
            fixture.provider.requests.map(\.temperature) == [1, 2, nil, nil],
            "creativity reaches the route as temperature, clamped, or not at all, and never Gemini")
        expect(
            fixture.routes.last == .api(connection: gemini.id, model: "gemini-3.8-flash", effort: nil),
            "judged by the route that answers, a named one included")
    }

    static func aDanglingPickFallsBackToChat() {
        let fixture = Gate()
        defer { fixture.close() }
        let chat = fixture.aiSettings.defaultModel
        fixture.gate.settings.select(.api(connection: UUID(), model: "gone", effort: nil))
        expect(chat != nil && fixture.gate.selection() == chat, "a deleted pick answers with AI Chat's model")
        fixture.gate.settings.select(.claude(model: "sonnet", effort: nil))
        expect(fixture.gate.selection() == .claude(model: "sonnet", effort: nil), "a live pick is used")
    }

    // MARK: - Settings

    static func settingsRoundTrip() {
        let suite = "ext-ai-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            expect(false, "a scratch defaults suite opens")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExtensionAISettingsStore(defaults: defaults)
        expect(
            !store.isEnabled && !store.honorsModels && store.model == nil && store.grants.isEmpty,
            "everything starts off")

        store.isEnabled = true
        store.honorsModels = true
        store.select(.claude(model: "sonnet", effort: "high"))
        store.setGrant(true, for: "color-picker")
        store.setGrant(false, for: "lorem")
        let reloaded = ExtensionAISettingsStore(defaults: defaults)
        expect(reloaded.isEnabled && reloaded.honorsModels, "both switches persist")
        expect(reloaded.model == .claude(model: "sonnet", effort: "high"), "the model persists")
        expect(reloaded.grants == ["color-picker": true, "lorem": false], "both answers persist")

        store.setGrant(nil, for: "color-picker")
        expect(store.grants == ["lorem": false], "clearing an answer asks again")
        store.setGrant(true, for: "a")
        store.forget(["lorem"])
        expect(store.grants == ["a": true], "forget drops the named extensions")
        store.forgetAll()
        let grantsKey = AppSettingsKey.extensionsAIGrants.rawValue
        expect(store.grants.isEmpty && defaults.object(forKey: grantsKey) == nil, "no answers, no key")
        store.select(nil)
        expect(
            defaults.object(forKey: AppSettingsKey.extensionsAIModel.rawValue) == nil,
            "following AI Chat stores nothing")
        expect(ExtensionAISettingsStore(defaults: defaults).model == nil, "and reloads as following")
    }
}
