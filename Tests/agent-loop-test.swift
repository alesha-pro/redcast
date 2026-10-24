import Foundation

/// The fork's agent loop against upstream's: same script, same events, same requests.
@main
@MainActor
struct AgentLoopTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() async {
        await bothLoopsAgree()
        constantsMatchUpstream()
        await unofferedNamesNeverReachMCP()
        await signalsLandBetweenACallsRows()
        await stopReachesTheRunningCall()
        await aTurnWithoutCallsPassesThrough()
        await aSimpleQuestionIsOneRound()
        await steeringIsReadAtTheNextStep()
        await aLongRunWrapsUpThenHandsOver()
        await aHandOverThatSaysNothingStillHandsOver()
        await anIgnoredHandOverIsEnforced()
        await theHistoryWallHandsOver()
        await anUnattendedRunHandsOverOnTime()
        await theClockStopsALongCall()
        await anInterruptedReplyComesBack()
        await aPlanIsKeptReadBackAndReported()
        await aFailedRunSaysWhereItsPlanStood()
        effortsGrowAndStayWhereTheyWere()
        await reasoningRidesTheCallsItMade()
        anEditDropsTheThinkingAfterIt()
        reasoningCountsAndIsShed()
        await aCutReplysCallsNeverRun()
        await aCutAnswerIsNeverSilent()
        await anAgentTurnCostsEveryRound()
        await theSpendMeterHearsEachRoundsCost()
        await aLongTurnElidesInsteadOfStopping()
        await callsThatMayShareARoundDo()
        await aCallThatMayNotRunsAlone()
        await aRoundIsNeverWiderThanFour()
        theDelegateToolOnlyReadsAndMayShareARound()
        await aSubAgentAnswersInsideItsParentsTurn()
        await aSubAgentIsBounded()
        await stopReachesASubAgent()
        await aSubAgentsSpendIsHeardAsItLands()
        await subAgentsRunSideBySideWithinTheirAllowance()
        retriesWaitAsThePolicySays()
        await aBusyRouteIsAskedAgain()
        await retriesEndAndAnAnswerIsNeverRepeated()
        await stopEndsAWaitingRetry()
        await anOverflowShedsTheWindowOnce()
        await aRefusedOutputCapIsDropped()
        await aRefusedReasoningFieldIsDropped()
        await compactionAddsNothingWhileNothingIsDropped()
        await compactionSummarisesOnceThenReuses()
        await aFailedSummaryLeavesTheTurnAsBuilt()
        await stopReachesTheSummary()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static let turn = AIRequest(
        instructions: "Be brief.", messages: [AIMessage(role: .user, text: "go")],
        conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"))

    static func call(_ id: String, _ name: String = "fs_read", _ arguments: String = "{}") -> AIStreamEvent {
        .toolCallRequested(AIToolCall(id: id, name: name, arguments: arguments))
    }

    static func toolset(
        _ providers: [any AgentToolProvider], mcp invoker: RecordingInvoker = RecordingInvoker(result: "mcp"),
        families: Set<AgentToolKind> = AgentToolKind.defaults
    ) -> AgentToolset {
        AgentToolset(
            turn: AgentTurn(
                profile: AgentProfile(name: "Loop", directory: "/tmp", tools: families), skills: [],
                memoryURL: URL(fileURLWithPath: "/tmp/memory.md"), mode: .chat(UUID())),
            providers: providers,
            mcpTools: [
                AITool(name: "srv__read", description: "", parameters: .object([:]), origin: "Server")
            ],
            mcp: { await invoker.invoke($0) }, ask: { _, _ in false })
    }

    static func collect(_ provider: any AIProvider) async -> (events: [AIStreamEvent], failure: String?) {
        var events: [AIStreamEvent] = []
        do {
            for try await event in provider.stream(turn) { events.append(event) }
        } catch {
            return (events, error.localizedDescription)
        }
        return (events, nil)
    }

    // MARK: - Differential

    /// Runs one script through both loops over one toolset and compares everything they emit.
    static func differential(
        _ name: String, rounds: [[AIStreamEvent]], maxRounds: Int?,
        answer: @escaping @Sendable (AIToolCall) -> String = { _ in "contents" }
    ) async {
        let invoker = RecordingInvoker(result: "from the server")
        let files = FakeTools(names: ["fs_read", "fs_list"]) { call, _ in answer(call) }
        let tools = toolset([files], mcp: invoker)
        let upstreamBase = ScriptedProvider(rounds: rounds)
        let forkBase = ScriptedProvider(rounds: rounds)
        let upstream = await collect(
            AIToolLoopProvider(base: upstreamBase, tools: tools.tools, maxRounds: maxRounds) { call in
                await tools.run(call, signal: { _ in })
            })
        let fork = await collect(AgentLoopProvider(base: forkBase, toolset: tools, budget: .roomy))
        expect(fork.events == upstream.events, "\(name): both loops emit the same events")
        expect(
            fork.failure == upstream.failure, "\(name): and end the same way, \(fork.failure ?? "finished")")
        expect(forkBase.requests == upstreamBase.requests, "\(name): and send the model the same requests")
        expect(!forkBase.requests.isEmpty, "\(name): the script ran")
    }

    static func bothLoopsAgree() async {
        await differential(
            "two rounds of calls", rounds: [
                [.text("Looking."), call("c1"), call("c2", "srv__read")],
                [call("c3", "fs_list")],
                [.text("Done."), .finished]
            ], maxRounds: 25)
        let forever = Array(repeating: [call("c")], count: 40)
        await differential(
            "a 40 KB result", rounds: [[call("c1")], [.text("ok"), .finished]], maxRounds: 25
        ) { _ in String(repeating: "x", count: 40 * 1_024) }
        await differential(
            "unlimited rounds", rounds: forever + [[.text("done"), .finished]], maxRounds: nil)
        await differential(
            "reasoning, searches and usage", rounds: [
                [
                    .thinking, .reasoning("plan"), .usage(AIUsage(inputTokens: 10, outputTokens: 2)),
                    call("c1")
                ],
                [.searching("q"), .searched("q"), .text("ok"), .usage(AIUsage(inputTokens: 20)), .finished]
            ], maxRounds: 25)
        let thought = AIReasoningReplay(
            route: "openrouter.ai", model: "m", form: .details, text: "check",
            items: [.object(["type": .string("reasoning.encrypted"), "data": .string("e")])])
        await differential(
            "reasoning sent back", rounds: [
                [.thinking, .reasoning("check"), .reasoningReplay(thought), call("c1")],
                [.text("ok"), .finished]
            ], maxRounds: 25)
        await differential(
            "a reply the output cap cut", rounds: [
                [.text("Writing."), call("c1", "fs_read", #"{"path":"a"#), call("c2"), .outputLimit],
                [call("c3")],
                [.text("Done."), .finished]
            ], maxRounds: 25)
        await differential(
            "a priced turn", rounds: [
                [.usage(AIUsage(inputTokens: 10, costUSD: 0.01)), call("c1")],
                [.usage(AIUsage(inputTokens: 15)), call("c2")],
                [.text("ok"), .usage(AIUsage(inputTokens: 20, costUSD: 0.02)), .finished]
            ], maxRounds: 25)
    }

    static func constantsMatchUpstream() {
        expect(
            AgentTurnBudget.resultBytes == AIToolLoopProvider.maxResultBytes,
            "a result is cut where upstream cuts it")
        expect(
            AgentTurnBudget.turnResultBytes == 4 * AIToolLoopProvider.maxTurnResultBytes,
            "a turn's results may run to four times upstream's, since old ones are elided")
        expect(
            AgentTurnBudget.historyBytes == AIToolLoopProvider.maxTurnHistoryBytes,
            "and an unlimited turn hits the same wall")
    }

    // MARK: - The fork's own behaviour

    static func unofferedNamesNeverReachMCP() async {
        let invoker = RecordingInvoker(result: "from the server")
        let base = ScriptedProvider(rounds: [
            [call("u1", "nope")], [call("m1", "srv__read")], [.text("ok"), .finished]
        ])
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "contents" }], mcp: invoker)
        let events = await collect(AgentLoopProvider(base: base, toolset: tools, budget: .roomy)).events
        expect(events.contains(.toolResult(id: "u1", isError: true)), "a name nobody offered fails")
        expect(
            base.requests[1].messages.last?.toolResult?.content == "There is no tool called nope.",
            "and tells the model so")
        expect(invoker.calls.map(\.name) == ["srv__read"], "only the offered MCP name reaches MCP")
    }

    static func signalsLandBetweenACallsRows() async {
        let searcher = FakeTools(names: ["fs_read"]) { _, context in
            context.signal(.searching("q"))
            context.signal(.searched("q"))
            return "found"
        }
        let base = ScriptedProvider(rounds: [[call("s1")], [.text("ok"), .finished]])
        let events = await collect(
            AgentLoopProvider(base: base, toolset: toolset([searcher]), budget: .roomy)
        ).events
        expect(
            Array(events.prefix(4)) == [
                .toolCall(id: "s1", origin: "Files", title: "FS_READ"), .searching("q"), .searched("q"),
                .toolResult(id: "s1", isError: false)
            ],
            "a call's signals arrive between its row opening and closing, got \(events)")
    }

    static func stopReachesTheRunningCall() async {
        let sleeper = Sleeper()
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in await sleeper.sleep() }])
        let base = ScriptedProvider(rounds: [[call("z1")], [.text("never"), .finished]])
        let loop = AgentLoopProvider(base: base, toolset: tools, budget: .roomy)
        let log = EventLog()
        let consumer = Task {
            do {
                for try await event in loop.stream(turn) { log.append(event) }
            } catch {}
        }
        while !sleeper.started { try? await Task.sleep(for: .milliseconds(10)) }
        let stopped = ContinuousClock.now
        consumer.cancel()
        await consumer.value
        while sleeper.noticed == nil { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(200))
        expect(
            (sleeper.noticed ?? .now) - stopped < .milliseconds(100),
            "Stop reaches the running call at once")
        expect(!log.events.contains(.finished), "a stopped turn never claims to have finished")
        expect(base.requests.count == 1, "and never sends the model another round")
    }

    static func aTurnWithoutCallsPassesThrough() async {
        let usage = AIUsage(inputTokens: 5, outputTokens: 1)
        let script: [AIStreamEvent] = [.text("Hi"), .reasoning("r"), .usage(usage), .finished]
        let base = ScriptedProvider(rounds: [script])
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let events = await collect(AgentLoopProvider(base: base, toolset: tools, budget: .roomy)).events
        expect(base.requests.count == 1, "a turn that calls nothing is one request")
        expect(base.requests.first?.tools == tools.tools, "armed with the turn's tools")
        expect(events == script, "and its events pass through unchanged")
    }

    /// DeepSeek refuses a thinking round whose earlier calls come back without their reasoning.
    static func reasoningRidesTheCallsItMade() async {
        let thought = AIReasoningReplay(
            route: "api.deepseek.com", model: "deepseek-flash", form: .reasoningContent, text: "Read it first.")
        let base = ScriptedProvider(rounds: [
            [.thinking, .reasoning("Read it first."), .reasoningReplay(thought), call("c1")],
            [call("c2")],
            [.text("ok"), .finished]
        ])
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let events = await collect(AgentLoopProvider(base: base, toolset: tools, budget: .roomy)).events
        let replies = base.requests.last?.messages.filter { $0.role == .assistant } ?? []
        expect(
            replies.map(\.reasoning) == [thought, nil],
            "each round's reasoning goes back on the message with its calls, and only there")
        expect(
            events.filter { if case .reasoningReplay = $0 { true } else { false } } == [.reasoningReplay(thought)],
            "and is handed on once, for the chat to keep for that model's later turns")
    }

    /// Claude signs a thinking block over all before it: an elided result voids every later block.
    static func anEditDropsTheThinkingAfterIt() {
        let signed = AIReasoningReplay(
            route: "api.anthropic.com", model: "claude-opus-5-5", form: .blocks, text: "",
            items: [.object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("s")])])
        let gemini = AIReasoningReplay(
            route: "generativelanguage.googleapis.com", model: "gemini-3.5-flash", form: nil, text: "")
        let page = String(repeating: "p", count: 100 * 1_024)
        func reply(_ id: String, _ reasoning: AIReasoningReplay) -> AIMessage {
            AIMessage(
                role: .assistant, text: "", toolCalls: [AIToolCall(id: id, name: "fs_read", arguments: "{}")],
                reasoning: reasoning)
        }
        func result(_ id: String) -> AIMessage {
            AIMessage(role: .tool, text: "", toolResult: AIToolResult(callID: id, content: page, isError: false))
        }
        var messages = [
            AIMessage(role: .user, text: "go"), reply("a", signed), result("a"), reply("b", signed), result("b"),
            reply("c", gemini), result("c"), reply("d", signed), result("d")
        ]
        let saved = AgentTurnBudget.elide(&messages, turnStart: 1, keepFrom: 7)
        expect(saved > 0 && messages[2].toolResult?.content.hasPrefix("[Earlier") == true, "the oldest result went")
        expect(
            [1, 3, 7].allSatisfy { messages[$0].reasoning?.items.isEmpty == true && !messages[$0].toolCalls.isEmpty },
            "Claude's oldest blocks go from the start, and every one after the edit is dropped for good")
        expect(messages[5].reasoning == gemini, "while a route that signs no prefix keeps what it had")
    }

    /// Reasoning sent back rides every later round: it counts toward the wall, and goes when old.
    static func reasoningCountsAndIsShed() {
        let thought = String(repeating: "t", count: 60 * 1_024)
        let deepSeek = AIReasoningReplay(
            route: "api.deepseek.com", model: "deepseek-flash", form: .reasoningContent, text: thought)
        var budget = AgentTurnBudget()
        budget.carry("ok", calls: [], reasoning: deepSeek)
        expect(budget.carried == thought.utf8.count + 2, "what goes back with a reply counts toward the history wall")
        let signed = JSONValue.object(["type": .string("reasoning.encrypted"), "data": .string("sig")])
        let routed = AIReasoningReplay(
            route: "openrouter.ai", model: "google/gemini-3.5-pro", form: .details, text: thought,
            items: [.object(["type": .string("reasoning.text"), "text": .string(thought)]), signed])
        func reply(_ id: String, _ reasoning: AIReasoningReplay) -> AIMessage {
            AIMessage(
                role: .assistant, text: "", toolCalls: [AIToolCall(id: id, name: "fs_read", arguments: "{}")],
                reasoning: reasoning)
        }
        func result(_ id: String) -> AIMessage {
            AIMessage(role: .tool, text: "", toolResult: AIToolResult(callID: id, content: "x", isError: false))
        }
        var messages = [
            AIMessage(role: .user, text: "go"), reply("a", deepSeek), result("a"), reply("b", routed), result("b"),
            reply("c", deepSeek), result("c")
        ]
        let saved = AgentTurnBudget.elide(&messages, turnStart: 1, keepFrom: 5)
        expect(saved >= 2 * thought.utf8.count, "a turn's old reasoning is shed like its old results")
        expect(
            messages[1].reasoning
                == AIReasoningReplay(
                    route: "api.deepseek.com", model: "deepseek-flash", form: .reasoningContent, text: ""),
            "DeepSeek's goes, the field's place kept, as the route requires")
        expect(
            messages[3].reasoning?.items == [signed] && messages[3].reasoning?.text == "",
            "OpenRouter's text goes while its encrypted entry, which Gemini checks, stays")
        expect(messages[5].reasoning == deepSeek, "and the newest round keeps its reasoning whole")
        expect(messages.compactMap(\.toolResult?.content) == ["x", "x", "x"], "results too small to stub stay")
    }

    /// pi's rule: a call from a reply the output cap cut is answered, never run, and asked again.
    static func aCutReplysCallsNeverRun() async {
        let ran = Heard()
        let writer = FakeTools(names: ["fs_write"], risk: .change) { _, _ in
            ran.append(1)
            return "wrote"
        }
        let base = ScriptedProvider(rounds: [
            [call("w1", "fs_write", ##"{"path":"r.md","content":"# Rep"##), .outputLimit],
            [call("w2", "fs_write", ##"{"path":"r.md","content":"# Report"}"##)],
            [.text("Saved."), .finished]
        ])
        let loop = AgentLoopProvider(
            base: base, toolset: toolset([writer]), budget: .roomy, outputCap: AgentTurnBudget.outputTokens)
        let events = await collect(loop).events
        expect(ran.values.count == 1, "only the whole call runs")
        expect(
            events.contains(.toolResult(id: "w1", isError: true)), "the cut call's row closes as failed")
        expect(
            base.requests[1].messages.last?.toolResult?.content
                == #"Tool call "fs_write" was not executed: the response hit the output token limit, so "#
                + "its arguments may be truncated. Re-issue the tool call with complete arguments.",
            "and the model reads pi's words for it")
        let asked = AIOutputCap(tokens: AgentTurnBudget.outputTokens, forced: false)
        let forced = AIOutputCap(tokens: AgentTurnBudget.outputTokens, forced: true)
        expect(
            base.requests.map(\.outputCap) == [asked, forced, forced],
            "an agent's round asks for its cap where a route needs a number, and every route after a cut, "
                + "got \(base.requests.map(\.outputCap))")
    }

    /// A reply the limit cut before it answered is asked again with room; one cut mid-answer says so.
    static func aCutAnswerIsNeverSilent() async {
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let thinker = ScriptedProvider(rounds: [
            [.thinking, .reasoning("long thought"), .outputLimit, .finished],
            [.thinking, .reasoning("short"), .text("42."), .finished]
        ])
        let retried = await collect(
            AgentLoopProvider(base: thinker, toolset: tools, budget: .roomy, outputCap: AgentTurnBudget.outputTokens))
        expect(
            thinker.requests.count == 2 && thinker.requests.last?.outputCap?.forced == true
                && texts(retried.events) == "42.",
            "a reply the route's own default cut before a word is asked again, once, with the cap, got "
                + "\(texts(retried.events))")
        let stuck = ScriptedProvider(rounds: [
            [.reasoning("a"), .outputLimit, .finished], [.reasoning("b"), .outputLimit, .finished]
        ])
        let silent = await collect(
            AgentLoopProvider(base: stuck, toolset: tools, budget: .roomy, outputCap: AgentTurnBudget.outputTokens))
        expect(
            stuck.requests.count == 2
                && texts(silent.events) == "The model reached its output limit before it answered.",
            "and if the room runs out again the reply says so instead of standing empty")
        let long = ScriptedProvider(rounds: [[.text("Part one"), .outputLimit, .finished]])
        let cut = await collect(
            AgentLoopProvider(base: long, toolset: tools, budget: .roomy, outputCap: AgentTurnBudget.outputTokens))
        expect(
            long.requests.count == 1
                && texts(cut.events) == "Part one\n\nThe reply was cut off at the model's output limit.",
            "an answer cut midway is kept and marked, never asked again to repeat itself")
    }

    static func anAgentTurnCostsEveryRound() async {
        let base = ScriptedProvider(rounds: [
            [.usage(AIUsage(inputTokens: 10, costUSD: 0.01)), call("c1")],
            [.text("ok"), .usage(AIUsage(inputTokens: 30, costUSD: 0.02)), .finished]
        ])
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let events = await collect(AgentLoopProvider(base: base, toolset: tools, budget: .roomy)).events
        let usages = events.compactMap { event -> AIUsage? in
            if case .usage(let usage) = event { usage } else { nil }
        }
        expect(abs((usages.last?.costUSD ?? 0) - 0.03) < 1e-12, "an agent reply costs its whole turn")
        expect(usages.last?.inputTokens == 30, "while its tokens stay the last round's")
    }

    /// A capped run's meter hears the turn's running cost after each round, and changes nothing.
    static func theSpendMeterHearsEachRoundsCost() async {
        let rounds: [[AIStreamEvent]] = [
            [.usage(AIUsage(inputTokens: 10, costUSD: 0.01)), call("c1")],
            [.usage(AIUsage(inputTokens: 15)), call("c2")],
            [.text("ok"), .usage(AIUsage(inputTokens: 30, costUSD: 0.02)), .finished]
        ]
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let plain = await collect(
            AgentLoopProvider(base: ScriptedProvider(rounds: rounds), toolset: tools, budget: .roomy)).events
        let heard = Heard()
        let metered = await collect(
            AgentSpendMeter(
                base: AgentLoopProvider(base: ScriptedProvider(rounds: rounds), toolset: tools, budget: .roomy)
            ) { heard.append($0) })
        expect(metered.events == plain, "the meter passes every event through unchanged")
        expect(metered.failure == nil, "and ends the turn as it ended")
        let costs = heard.values
        expect(costs.count == 3, "one report per usage that carries a cost, got \(costs)")
        expect(abs((costs.last ?? 0) - 0.03) < 1e-12, "the last is the whole turn's cost")
        expect(costs == costs.sorted(), "and the reports only ever grow")

        let failing = await collect(AgentSpendMeter(base: FailingProvider()) { heard.append($0) })
        expect(failing.failure != nil, "a route's failure still reaches the chat through the meter")
    }
}

extension AgentRunBudget {
    /// Far past any script here, so a test meets a limit only where it sets one.
    static let roomy = AgentRunBudget(rounds: 1_000)
}

final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    var values: [Double] { lock.withLock { stored } }

    func append(_ value: Double) {
        lock.withLock { stored.append(value) }
    }
}

struct FailingProvider: AIProvider {
    func stream(_ request: AIRequest) -> AIProviderStream {
        AIProviderStream { $0.finish(throwing: AIProviderError.responseFailed("down")) }
    }
}

// MARK: - Long turns

extension AgentLoopTests {
    /// Past upstream's 128 KB a turn keeps going, and resends stubs for its oldest results.
    static func aLongTurnElidesInsteadOfStopping() async {
        let page = FakeTools(names: ["fs_read"]) { _, _ in String(repeating: "p", count: 30 * 1_024) }
        let base = ScriptedProvider(rounds: (1...8).map { [call("p\($0)")] } + [[.text("ok"), .finished]])
        let outcome = await collect(AgentLoopProvider(base: base, toolset: toolset([page]), budget: .roomy))
        expect(
            outcome.failure == nil && outcome.events.last == .finished, "eight 30 KB pages finish the turn")
        expect(
            !outcome.events.contains(.toolResult(id: "p5", isError: true)),
            "where upstream's budget would have refused the fifth")
        let last = base.requests.last?.messages.compactMap(\.toolResult?.content) ?? []
        expect(
            last.count == 8 && last.first?.hasPrefix("[Earlier fs_read result elided") == true,
            "old pages are stubbed")
        expect(
            last.reduce(0) { $0 + $1.utf8.count } <= AgentTurnBudget.elideAbove,
            "so what each round resends stays under the watermark")
    }
}

// MARK: - Parallel rounds

extension AgentLoopTests {
    static func callsThatMayShareARoundDo() async {
        let gauge = Gauge()
        let reader = FakeTools(names: ["fs_read"], concurrent: true) { call, _ in
            await gauge.hold(.milliseconds(200))
            return call.id
        }
        let base = ScriptedProvider(rounds: [[call("r1"), call("r2"), call("r3")], [.text("ok"), .finished]])
        let started = ContinuousClock.now
        let events = await collect(AgentLoopProvider(base: base, toolset: toolset([reader]), budget: .roomy))
            .events
        expect(ContinuousClock.now - started < .milliseconds(400), "three 200 ms reads share one round")
        let rows = events.filter {
            switch $0 {
            case .toolCall, .toolResult: true
            default: false
            }
        }
        expect(
            Array(rows.prefix(3)) == ["r1", "r2", "r3"].map {
                .toolCall(id: $0, origin: "Files", title: "FS_READ")
            },
            "every row of a batch opens before any closes")
        expect(
            base.requests[1].messages.compactMap(\.toolResult?.content) == ["r1", "r2", "r3"],
            "and the model reads the results in the order it asked")
    }

    static func aCallThatMayNotRunsAlone() async {
        let gauge = Gauge()
        let seenAlone = Flag()
        let reader = FakeTools(names: ["fs_read"], concurrent: true) { call, _ in
            await gauge.hold(.milliseconds(100))
            return call.id
        }
        let writer = FakeTools(names: ["fs_write"], risk: .change) { call, _ in
            if await gauge.hold(.milliseconds(50)) == 1 { seenAlone.set() }
            return call.id
        }
        let base = ScriptedProvider(rounds: [
            [call("r1"), call("r2"), call("w1", "fs_write"), call("r3"), call("r4")], [.text("ok"), .finished]
        ])
        let events = await collect(
            AgentLoopProvider(base: base, toolset: toolset([reader, writer]), budget: .roomy)
        ).events
        let order: [String] = events.compactMap {
            switch $0 {
            case .toolCall(let id, _, _): "+" + id
            case .toolResult(let id, _): "-" + id
            default: nil
            }
        }
        let write = order.firstIndex(of: "+w1") ?? 0
        expect(
            Set(order[..<write]) == ["+r1", "+r2", "-r1", "-r2"] && order[write + 1] == "-w1",
            "a change runs alone, after its neighbours finish and before the next start, got \(order)")
        expect(seenAlone.isSet, "with nothing else running")
        expect(
            base.requests[1].messages.compactMap(\.toolResult?.content) == ["r1", "r2", "w1", "r3", "r4"],
            "in its place among the results")
    }

    static func aRoundIsNeverWiderThanFour() async {
        let gauge = Gauge()
        let reader = FakeTools(names: ["fs_read"], concurrent: true) { call, _ in
            await gauge.hold(.milliseconds(50))
            return call.id
        }
        let base = ScriptedProvider(rounds: [(1...6).map { call("r\($0)") }, [.text("ok"), .finished]])
        _ = await collect(AgentLoopProvider(base: base, toolset: toolset([reader]), budget: .roomy))
        expect(gauge.peak == AgentLoopProvider.width, "at most four calls run at once, got \(gauge.peak)")
    }
}

// MARK: - Sub-agents

extension AgentLoopTests {
    static func delegateCall(_ id: String, name: String = "Find config", task: String = "Where is X?")
        -> AIStreamEvent
    {
        call(id, AgentDelegateTools.name, #"{"name":"\#(name)","task":"\#(task)"}"#)
    }

    /// The child's toolset as the coordinator builds it: read-only, no MCP, nobody to ask.
    static func childTools(_ providers: [any AgentToolProvider]) -> AgentToolset {
        AgentToolset(
            turn: AgentTurn(
                profile: AgentProfile(name: "Loop", directory: "/tmp", access: .readOnly), skills: [],
                memoryURL: URL(fileURLWithPath: "/tmp/memory.md"), mode: .unattended(UUID())),
            providers: providers, mcpTools: [], offering: AgentToolRisk.reads,
            mcp: { .failure($0.id, "mcp") }, ask: { _, _ in false })
    }

    static func theDelegateToolOnlyReadsAndMayShareARound() {
        let full = AgentProfile(
            name: "Loop", directory: "/tmp", access: .fullAccess, tools: Set(AgentToolKind.allCases))
        let delegate = AgentDelegateTools(
            base: ScriptedProvider(rounds: []), toolset: childTools([]), instructions: "")
        let specs = delegate.specs(
            for: AgentTurn(
                profile: full, skills: [], memoryURL: URL(fileURLWithPath: "/tmp/memory.md"),
                mode: .chat(UUID())))
        expect(
            specs.map(\.tool.name) == [AgentDelegateTools.name] && specs.first?.family == .delegate
                && specs.first?.risk == .read && specs.first?.concurrent == true,
            "delegate is the Sub-agents family's, changes nothing itself, and children of a round run together")
        let others =
            AgentToolbox.tools(for: full, hasSkills: true).map(\.name)
            + [AgentPlan.name, WebSearchTool.name, "screen_context"]
        expect(!others.contains(AgentDelegateTools.name), "and its name is nobody else's")
    }

    static func aSubAgentAnswersInsideItsParentsTurn() async {
        let base = ScriptedProvider(rounds: [
            [.usage(AIUsage(inputTokens: 10, costUSD: 0.01)), delegateCall("d1")],
            [.text("Looking."), call("c1"), .usage(AIUsage(inputTokens: 5, costUSD: 0.002))],
            [.text("X lives in a.txt."), .usage(AIUsage(inputTokens: 6, costUSD: 0.003)), .finished],
            [.text("Done."), .usage(AIUsage(inputTokens: 20, costUSD: 0.02)), .finished]
        ])
        let child = childTools([
            FakeTools(names: ["fs_read"]) { _, _ in "a.txt: X" },
            FakeTools(names: ["fs_write"], risk: .change) { _, _ in "wrote" },
            FakeTools(names: ["notes_keep"], risk: .own) { _, _ in "kept" }
        ])
        let delegate = AgentDelegateTools(base: base, toolset: child, instructions: "Be a sub-agent.")
        let parent = toolset([delegate], families: [.delegate])
        let outcome = await collect(AgentLoopProvider(base: base, toolset: parent, budget: .roomy))
        expect(outcome.failure == nil && outcome.events.last == .finished, "the parent's turn finishes")
        expect(
            outcome.events.contains(.toolCall(id: "d1", origin: "Loop", title: "delegate: Find config"))
                && outcome.events.contains(.toolResult(id: "d1", isError: false)),
            "its row names the sub-task, got \(outcome.events)")
        expect(
            !outcome.events.contains { if case .toolCall(id: "c1", _, _) = $0 { true } else { false } },
            "and the sub-agent's own calls stay out of the transcript")
        expect(base.requests.count == 4, "two rounds of the child sit between the parent's two")
        guard base.requests.count == 4 else {
            return expect(false, "the script ran to its end, got \(base.requests.count): \(outcome)")
        }
        let request = base.requests[1]
        expect(
            request.instructions == "Be a sub-agent."
                && request.messages == [AIMessage(role: .user, text: "Where is X?")],
            "the child starts from its own prompt and the task alone")
        expect(
            request.tools.map(\.name) == ["fs_read"],
            "and is offered reading only: no change, nothing of its own to write, no delegate")
        expect(
            base.requests[3].messages.last?.toolResult?.content == "X lives in a.txt.",
            "its answer is what it said after its last call")
        let usages = outcome.events.compactMap { event -> AIUsage? in
            if case .usage(let usage) = event { usage } else { nil }
        }
        expect(
            abs((usages.last?.costUSD ?? 0) - 0.035) < 1e-12,
            "and what it spent is billed into the parent's reply, got \(usages.last?.costUSD ?? 0)")
        expect(usages.last?.inputTokens == 20, "while the tokens stay the parent's last round's")

        let flat = AgentToolset(
            turn: AgentTurn(
                profile: AgentProfile(name: "Loop", directory: "/tmp", tools: [.files]), skills: [],
                memoryURL: URL(fileURLWithPath: "/tmp/memory.md"), mode: .chat(UUID())),
            providers: [delegate], mcpTools: [], mcp: { .failure($0.id, "mcp") }, ask: { _, _ in false })
        expect(flat.tools.isEmpty, "an agent without Sub-agents ticked, as every child is, has no delegate")
        expect(
            !AgentToolKind.defaults.contains(.delegate)
                && !AgentProfile(name: "New", directory: "/tmp").tools.contains(.delegate),
            "Sub-agents is off for a new agent")
    }

    static func aSubAgentIsBounded() async {
        let long = String(repeating: "é", count: 20 * 1_024)
        let talker = ScriptedProvider(rounds: [[.text(long), .finished]])
        let delegate = AgentDelegateTools(
            base: talker, toolset: childTools([FakeTools(names: ["fs_read"]) { _, _ in "x" }]),
            instructions: "")
        let context = AgentToolContext(
            turn: AgentTurn(
                profile: AgentProfile(name: "Loop", directory: "/tmp"), skills: [],
                memoryURL: URL(fileURLWithPath: "/tmp/memory.md"), mode: .chat(UUID())),
            consent: { _ in false }, signal: { _ in })
        let cut = await delegate.run(
            AIToolCall(id: "d", name: AgentDelegateTools.name, arguments: #"{"name":"n","task":"t"}"#),
            in: context)
        expect(
            !cut.isError && cut.content.utf8.count <= AgentDelegateTools.maxAnswerBytes + 64
                && cut.content.hasSuffix("…cut: the sub-agent's answer was longer."),
            "a long answer is cut under the executor's 28 KB and says so")
        expect(
            AgentDelegateTools.maxAnswerBytes < AgentTurnBudget.resultBytes,
            "so the parent's budget never cuts it again")

        let looping = ScriptedProvider(rounds: Array(repeating: [call("c")], count: 20))
        let lost = AgentDelegateTools(
            base: looping, toolset: childTools([FakeTools(names: ["fs_read"]) { _, _ in "x" }]),
            instructions: "")
        let stopped = await lost.run(
            AIToolCall(id: "d", name: AgentDelegateTools.name, arguments: #"{"name":"n","task":"t"}"#),
            in: context)
        expect(
            !stopped.isError && stopped.content == "The sub-task's budget ran out before it wrote an answer."
                && looping.requests.count == AgentRunBudget.subAgent.rounds + 2
                && looping.requests.last?.forbidsCalls == true,
            "a child that keeps calling is asked once more at its budget, then with calls off, and still hands "
                + "something back, got \(stopped.content)")

        let slow = ScriptedProvider(rounds: [[call("c")], [.text("Found X."), .finished]])
        let late = AgentDelegateTools(
            base: slow, toolset: childTools([FakeTools(names: ["fs_read"]) { _, _ in "x" }]), instructions: "",
            clock: AgentRunClock(limit: .seconds(60), from: .now - .seconds(59)))
        let timed = await late.run(
            AIToolCall(id: "d", name: AgentDelegateTools.name, arguments: #"{"name":"n","task":"t"}"#),
            in: context)
        expect(
            timed.content == "Found X." && slow.requests.count == 2
                && slow.requests.last?.messages.last?.text.contains("of 0 minutes used") == true,
            "a child started near its parent's end hands over after one round, got \(timed.content)")

        let idle = ScriptedProvider(rounds: [])
        let malformed = await AgentDelegateTools(base: idle, toolset: childTools([]), instructions: "").run(
            AIToolCall(id: "d", name: AgentDelegateTools.name, arguments: #"{"name":"","task":"t"}"#),
            in: context)
        expect(malformed.isError && idle.requests.isEmpty, "a call with no name or task starts no child")
    }

    static func stopReachesASubAgent() async {
        let sleeper = Sleeper()
        let base = ScriptedProvider(rounds: [[delegateCall("d1")], [call("z1")], [.text("never"), .finished]])
        let child = childTools([FakeTools(names: ["fs_read"]) { _, _ in await sleeper.sleep() }])
        let parent = toolset(
            [AgentDelegateTools(base: base, toolset: child, instructions: "")], families: [.delegate])
        let loop = AgentLoopProvider(base: base, toolset: parent, budget: .roomy)
        let consumer = Task {
            do {
                for try await _ in loop.stream(turn) {}
            } catch {}
        }
        while !sleeper.started { try? await Task.sleep(for: .milliseconds(10)) }
        let stopped = ContinuousClock.now
        consumer.cancel()
        await consumer.value
        while sleeper.noticed == nil { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(200))
        expect(
            (sleeper.noticed ?? .now) - stopped < .milliseconds(100),
            "Stop reaches the sub-agent's running call at once")
        expect(base.requests.count == 2, "and neither the child nor the parent asks the model again")
    }
}

extension AgentLoopTests {
    static func meteredParent(_ base: any AIProvider) -> AgentLoopProvider {
        let child = childTools([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let delegate = AgentDelegateTools(base: base, toolset: child, instructions: "")
        return AgentLoopProvider(base: base, toolset: toolset([delegate], families: [.delegate]), budget: .roomy)
    }

    static func cents(_ values: [Double]) -> [Double] {
        values.map { ($0 * 100).rounded() / 100 }
    }

    static func aSubAgentsSpendIsHeardAsItLands() async {
        let rounds: [[AIStreamEvent]] = [
            [.usage(AIUsage(inputTokens: 10, costUSD: 0.01)), delegateCall("d1")],
            [call("c1"), .usage(AIUsage(costUSD: 0.5))],
            [call("c2"), .usage(AIUsage(costUSD: 0.5))],
            [.text("Found."), .usage(AIUsage(costUSD: 0.5)), .finished],
            [.text("Done."), .usage(AIUsage(inputTokens: 20, costUSD: 0.01)), .finished]
        ]
        let heard = Heard()
        let metered = await collect(AgentSpendMeter(base: meteredParent(ScriptedProvider(rounds: rounds))) {
            heard.append($0)
        })
        expect(metered.failure == nil, "a metered parent with a sub-agent finishes")
        expect(
            cents(heard.values) == [0.01, 0.51, 1.01, 1.51, 1.52],
            "the meter hears each of the sub-agent's rounds as it ends, got \(heard.values)")

        let hanging = ScriptThenHang(rounds: Array(rounds.prefix(4)))
        let log = EventLog()
        let loop = meteredParent(hanging)
        let consumer = Task {
            do {
                for try await event in loop.stream(turn) { log.append(event) }
            } catch {}
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while cents([lastCost(log.events) ?? 0]) != [1.51] || hanging.requests < 5, .now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        consumer.cancel()
        await consumer.value
        let shown = log.events.compactMap { event -> AIUsage? in
            if case .usage(let usage) = event { usage } else { nil }
        }.last
        expect(
            hanging.requests == 5 && cents([shown?.costUSD ?? 0]) == [1.51],
            "stopped while the parent's next round streams, the reply keeps the sub-agent's spend")
        expect(shown?.inputTokens == 10, "beside the tokens of the parent's last round")

        let pair = ScriptedProvider(rounds: [
            [.usage(AIUsage(costUSD: 0.01)), delegateCall("d1"), delegateCall("d2", name: "Other")],
            [.text("A."), .usage(AIUsage(costUSD: 0.5)), .finished],
            [.text("B."), .usage(AIUsage(costUSD: 0.25)), .finished],
            [.text("Done."), .usage(AIUsage(costUSD: 0.01)), .finished]
        ])
        let both = Heard()
        _ = await collect(AgentSpendMeter(base: meteredParent(pair)) { both.append($0) })
        let landed = cents(both.values)
        expect(
            pair.requests.count == 4 && [[0.01, 0.51, 0.76, 0.77], [0.01, 0.26, 0.76, 0.77]].contains(landed),
            "two sub-agents of one round run side by side and are each heard as they land, got \(both.values)")
    }
}

// MARK: - Retries

extension AgentLoopTests {
    static let quick = AgentRetryPolicy(
        delays: [10, 20, 40, 80].map { Duration.milliseconds($0) }, jitter: 0.1, longestWait: .seconds(60))
    static let busy = AIProviderRecoverableError(
        kind: .transient(retryAfter: nil), message: "The provider is temporarily unavailable (HTTP 503).")

    static func retriesWaitAsThePolicySays() {
        let policy = AgentRetryPolicy.standard
        expect(
            policy.delay(before: 1, after: busy, random: 0.5) == .seconds(2)
                && policy.delay(before: 4, after: busy, random: 0.5) == .seconds(16),
            "pi's backoff doubles from two seconds")
        expect(
            policy.delay(before: 5, after: busy, random: 0.5) == nil, "and gives up after four retries")
        let low = policy.delay(before: 2, after: busy, random: 0) ?? .zero
        let high = policy.delay(before: 2, after: busy, random: 1) ?? .zero
        let near = { (value: Duration, target: Duration) in abs((value - target) / .milliseconds(1)) < 1 }
        expect(
            near(low, .milliseconds(3_600)) && near(high, .milliseconds(4_400)),
            "a tenth either way, got \(low) \(high)")
        let limited = AIProviderRecoverableError(kind: .transient(retryAfter: .seconds(7)), message: "429")
        expect(
            policy.delay(before: 1, after: limited, random: 0.5) == .seconds(7),
            "a Retry-After longer than the backoff is waited out")
        let closed = AIProviderRecoverableError(kind: .transient(retryAfter: .seconds(600)), message: "429")
        expect(policy.delay(before: 1, after: closed, random: 0.5) == nil, "but not one past a minute")
        expect(
            policy.delay(before: 1, after: AIProviderError.responseFailed("API key rejected"), random: 0.5) == nil
                && policy.delay(
                    before: 1, after: AIProviderRecoverableError(kind: .overflow, message: "full"), random: 0.5)
                    == nil,
            "a refusal or a full window is never simply asked again")
    }

    /// 5xx, 429 and dropped connections before an answer are asked again, and billed once each.
    static func aBusyRouteIsAskedAgain() async {
        let base = FlakyProvider(
            failures: [busy, busy], spentBeforeFailing: 0.004,
            then: [
                [.usage(AIUsage(inputTokens: 10, costUSD: 0.01)), call("c1")],
                [.text("ok"), .usage(AIUsage(inputTokens: 20, costUSD: 0.02)), .finished]
            ])
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let outcome = await collect(
            AgentLoopProvider(base: base, toolset: tools, budget: .roomy, retry: quick, origin: "Loop"))
        expect(outcome.failure == nil && outcome.events.last == .finished, "two busy answers, then the turn ends")
        expect(base.requests.count == 4, "the first round is asked three times, the second once")
        let rows = outcome.events.filter {
            switch $0 {
            case .toolCall(let id, _, _), .toolResult(let id, _): id.hasPrefix("tinycast-retry-")
            default: false
            }
        }
        expect(
            rows == [
                .toolCall(id: "tinycast-retry-1-1", origin: "Loop", title: AgentRetryPolicy.title(1, of: 4, reason: AgentRetryPolicy.reason(busy))),
                .toolResult(id: "tinycast-retry-1-1", isError: false),
                .toolCall(id: "tinycast-retry-1-2", origin: "Loop", title: AgentRetryPolicy.title(2, of: 4, reason: AgentRetryPolicy.reason(busy))),
                .toolResult(id: "tinycast-retry-1-2", isError: false)
            ],
            "each wait shows as a row that closes when the round is asked again, got \(rows)")
        expect(
            abs((lastCost(outcome.events) ?? 0) - 0.038) < 1e-12,
            "what a failed attempt reported is billed once, beside the rounds that passed, got "
                + "\(lastCost(outcome.events) ?? 0)")
        expect(
            base.requests[0] == base.requests[2], "the same request goes again, nothing of the failure in it")
    }

    static func retriesEndAndAnAnswerIsNeverRepeated() async {
        let down = FlakyProvider(failures: Array(repeating: busy, count: 9), then: [])
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let gaveUp = await collect(AgentLoopProvider(base: down, toolset: tools, budget: .roomy, retry: quick))
        expect(
            gaveUp.failure == busy.message && down.requests.count == 5,
            "four retries, then the failure stands in its own words, got \(gaveUp.failure ?? "none")")

        let halfway = FlakyProvider(failures: [busy], textBeforeFailing: "Half an ans", then: [[.text("x"), .finished]])
        let said = await collect(AgentLoopProvider(base: halfway, toolset: tools, budget: .roomy, retry: quick))
        expect(
            said.failure == busy.message && halfway.requests.count == 1,
            "a round that already showed text is not asked again, or the text would show twice")

        let refused = FlakyProvider(failures: [AIProviderError.responseFailed("API key rejected")], then: [])
        let rejected = await collect(AgentLoopProvider(base: refused, toolset: tools, budget: .roomy, retry: quick))
        expect(
            rejected.failure == "API key rejected" && refused.requests.count == 1,
            "and a refusal is never retried")
    }

    static func stopEndsAWaitingRetry() async {
        let slow = AgentRetryPolicy(delays: [.seconds(5)], jitter: 0, longestWait: .seconds(60))
        let base = FlakyProvider(failures: [busy], then: [[.text("never"), .finished]])
        let loop = AgentLoopProvider(
            base: base, toolset: toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }]), budget: .roomy,
            retry: slow, origin: "Loop")
        let log = EventLog()
        let consumer = Task {
            do {
                for try await event in loop.stream(turn) { log.append(event) }
            } catch {}
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !log.events.contains(where: { if case .toolCall = $0 { true } else { false } }), .now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let stopped = ContinuousClock.now
        consumer.cancel()
        await consumer.value
        expect(ContinuousClock.now - stopped < .milliseconds(500), "Stop ends the wait at once")
        try? await Task.sleep(for: .milliseconds(100))
        expect(base.requests.count == 1, "and the round is never asked again")
        expect(!log.events.contains(.finished), "nor does the turn claim to have finished")
    }

    /// dsh's rule: a full window is shed, old results first, and the round asked again.
    static func anOverflowShedsTheWindowOnce() async {
        let full = AIProviderRecoverableError(kind: .overflow, message: "maximum context length is 8192 tokens")
        let page = String(repeating: "p", count: 20 * 1_024)
        let base = FlakyProvider(
            failures: [], failAt: [3: full],
            then: [[call("c1")], [call("c2")], [.text("ok"), .finished]])
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in page }])
        let outcome = await collect(AgentLoopProvider(base: base, toolset: tools, budget: .roomy, retry: quick))
        expect(outcome.failure == nil && outcome.events.last == .finished, "the turn goes on after an overflow")
        let results = base.requests.last?.messages.compactMap(\.toolResult?.content) ?? []
        expect(
            base.requests.count == 4 && results.count == 2
                && results[0].hasPrefix("[Earlier fs_read result elided") && results[1] == page,
            "with the older round's result stubbed and the newest kept, got \(results.map(\.count))")

        let first = FlakyProvider(failures: [full, full], then: [[.text("x"), .finished]])
        let stuck = await collect(AgentLoopProvider(base: first, toolset: tools, budget: .roomy, retry: quick))
        expect(
            stuck.failure == full.message && first.requests.count == 1,
            "with nothing of the turn to shed and one question, the overflow stands")

        let growing = FlakyProvider(
            failures: [], failAt: [3: full, 4: full],
            then: [[call("c1")], [call("c2")], [.text("What I found, from what fits."), .finished]])
        let handed = await collect(AgentLoopProvider(base: growing, toolset: tools, budget: .roomy, retry: quick))
        let sent = growing.requests.last?.messages ?? []
        expect(
            handed.failure == nil && texts(handed.events) == "What I found, from what fits."
                && growing.requests.count == 5,
            "a window still full once the older rounds are shed hands over, got \(handed.failure ?? "")")
        expect(
            sent.compactMap(\.toolResult?.content).allSatisfy { $0.hasPrefix("[Earlier fs_read result elided") }
                && sent.last?.text.contains(AgentBudgetPolicy.windowFull) == true,
            "with every result shed and the reason said")
    }

    static func aRefusedOutputCapIsDropped() async {
        let refusal = AIProviderError.responseFailed(
            "The provider rejected the model or request (HTTP 400).\n\nmax_tokens: 16384 > 8192")
        let base = FlakyProvider(failures: [refusal], then: [[call("c1")], [.text("ok"), .finished]])
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let outcome = await collect(
            AgentLoopProvider(base: base, toolset: tools, budget: .roomy, outputCap: 16_384, retry: quick))
        expect(outcome.failure == nil, "a model that takes less output is asked again without the cap")
        expect(
            base.requests.map(\.outputCap) == [AIOutputCap(tokens: 16_384, forced: false), nil, nil],
            "and the rest of the turn goes without one, got \(base.requests.map(\.outputCap))")
        // vLLM's words: an overflow, since the cap counts against the window, yet the cap is to blame.
        let window = AIProviderRecoverableError(
            kind: .overflow,
            message: "'max_tokens' or 'max_completion_tokens' is too large: 32768. This model's maximum context "
                + "length is 32768 tokens and your request has 120 input tokens (32768 > 32768 - 120).")
        let local = FlakyProvider(failures: [window], then: [[.text("ok"), .finished]])
        let small = await collect(
            AgentLoopProvider(base: local, toolset: tools, budget: .roomy, outputCap: 32_768, retry: quick))
        expect(
            small.failure == nil
                && local.requests.map(\.outputCap) == [AIOutputCap(tokens: 32_768, forced: false), nil],
            "a small window that cannot also hold the cap is asked again without it, got \(small.failure ?? "")")
        let old = AIProviderRecoverableError(
            kind: .overflow,
            message: "This model's maximum context length is 8192 tokens. However, you requested 9000 tokens "
                + "(800 in the messages, 8200 in the completion).")
        expect(AgentRetryPolicy.refusesOutputCap(old), "older vLLM's words for it too")
        expect(
            !AgentRetryPolicy.refusesOutputCap(
                AIProviderRecoverableError(kind: .overflow, message: "prompt is too long: 210000 tokens > 200000")),
            "while a prompt too long for any cap is an overflow to shed")
    }

    /// A strict gateway that names a reasoning field it does not take is sent none for the rest of the run.
    static func aRefusedReasoningFieldIsDropped() async {
        let thought = AIReasoningReplay(route: "api.groq.com", model: "qwen3-32b", form: .reasoning, text: "Read it.")
        let signed = AIReasoningReplay(
            route: "api.groq.com", model: "qwen3-32b", form: .blocks, text: "",
            items: [.object(["type": .string("thinking"), "signature": .string("s")])])
        let groq = AIProviderError.responseFailed(
            "The provider rejected the model or request (HTTP 400).\n\n'messages.2' : for 'role:assistant' the "
                + "following must be satisfied[('messages.2' : property 'reasoning' is unsupported)]")
        let base = FlakyProvider(
            failures: [], failAt: [2: groq],
            then: [
                [.reasoningReplay(thought), call("c1")], [.reasoningReplay(thought), call("c2")],
                [.text("ok"), .finished]
            ])
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let outcome = await collect(AgentLoopProvider(base: base, toolset: tools, budget: .roomy, retry: quick))
        let carried = base.requests.map { $0.messages.compactMap(\.reasoning) }
        expect(outcome.failure == nil && texts(outcome.events) == "ok", "a refused field is not the run's end")
        expect(
            carried == [[], [thought], [], []],
            "the refused round is asked again without it, and no later round sends it, got \(carried)")
        expect(
            outcome.events.filter { if case .reasoningReplay = $0 { true } else { false } }.count == 2,
            "while the chat still hears each reply's reasoning")
        let mistral = AIProviderError.responseFailed(
            "HTTP 422: [{'type': 'extra_forbidden', 'loc': ('body', 'messages', 1, 'assistant', "
                + "'reasoning_content'), 'msg': 'Extra inputs are not permitted'}]")
        expect(AgentRetryPolicy.refusesReasoning(mistral), "pydantic's words for an unknown field too")
        let deepSeek = AIProviderError.responseFailed(
            "HTTP 400: The reasoning_content in the thinking mode must be passed back to the API.")
        expect(!AgentRetryPolicy.refusesReasoning(deepSeek), "DeepSeek asking for the field is no refusal of it")
        expect(
            !AgentRetryPolicy.refusesReasoning(AIProviderError.responseFailed("reasoning_effort is not supported")),
            "nor is a refused effort, which names another field")
        let claude = FlakyProvider(
            failures: [], failAt: [2: groq], then: [[.reasoningReplay(signed), call("c1")], [.text("ok"), .finished]])
        _ = await collect(AgentLoopProvider(base: claude, toolset: tools, budget: .roomy, retry: quick))
        expect(
            claude.requests.map { $0.messages.compactMap(\.reasoning) } == [[], [signed]],
            "Claude's signed blocks are never dropped this way: its tool loop must have them")
    }
}

/// Fails as a busy route would, a given number of times or at given requests, then plays a script.
final class FlakyProvider: AIProvider, @unchecked Sendable {
    private let script: ScriptedProvider
    private let lock = NSLock()
    private var failures: [any Error]
    private let failAt: [Int: any Error]
    private let spent: Double?
    private let text: String?
    private var seen: [AIRequest] = []

    init(
        failures: [any Error], failAt: [Int: any Error] = [:], spentBeforeFailing: Double? = nil,
        textBeforeFailing: String? = nil, then rounds: [[AIStreamEvent]]
    ) {
        self.failures = failures
        self.failAt = failAt
        spent = spentBeforeFailing
        text = textBeforeFailing
        script = ScriptedProvider(rounds: rounds)
    }

    var requests: [AIRequest] { lock.withLock { seen } }

    func stream(_ request: AIRequest) -> AIProviderStream {
        let failure: (any Error)? = lock.withLock {
            seen.append(request)
            if let planned = failAt[seen.count] { return planned }
            return failures.isEmpty ? nil : failures.removeFirst()
        }
        guard let failure else { return script.stream(request) }
        let spent = spent
        let text = text
        return AIProviderStream { continuation in
            if let text { continuation.yield(.text(text)) }
            if let spent { continuation.yield(.usage(AIUsage(costUSD: spent))) }
            continuation.finish(throwing: failure)
        }
    }
}

// MARK: - Cross-turn compaction

extension AgentLoopTests {
    static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentLoopTests-\(UUID().uuidString)")

    /// `count` messages of 1 KB, a question at every even index; the last is the turn's question.
    static func chat(_ count: Int, after earlier: [AgentCompaction.Entry] = []) -> [AgentCompaction.Entry] {
        earlier + (earlier.count..<earlier.count + count).map { index in
            AgentCompaction.Entry(
                id: UUID(), isUser: index.isMultiple(of: 2),
                text: "m\(index) " + String(repeating: "x", count: 1_000))
        }
    }

    /// What `ChatSession.requestMessages` would have sent: the last `count` messages.
    static func request(_ history: [AgentCompaction.Entry], keeping count: Int) -> AIRequest {
        AIRequest(
            instructions: "Be brief.",
            messages: history.suffix(count).map {
                AIMessage(role: $0.isUser ? .user : .assistant, text: $0.text)
            })
    }

    static func source(_ history: [AgentCompaction.Entry], file: URL) -> AgentCompaction.Source {
        AgentCompaction.Source(url: file, origin: "Loop", history: { history })
    }

    static func run(
        _ loop: AgentLoopProvider, _ request: AIRequest
    ) async -> (events: [AIStreamEvent], failure: String?) {
        var events: [AIStreamEvent] = []
        do {
            for try await event in loop.stream(request) { events.append(event) }
        } catch {
            return (events, error.localizedDescription)
        }
        return (events, nil)
    }

    static func lastCost(_ events: [AIStreamEvent]) -> Double? {
        events.compactMap { event -> Double? in
            if case .usage(let usage) = event { usage.costUSD } else { nil }
        }.last
    }

    static func compactionAddsNothingWhileNothingIsDropped() async {
        let file = folder.appendingPathComponent("whole.json")
        let history = chat(7)
        let script: [AIStreamEvent] = [.text("ok"), .finished]
        let base = ScriptedProvider(rounds: [script])
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let outcome = await run(
            AgentLoopProvider(base: base, toolset: tools, budget: .roomy, compaction: source(history, file: file)),
            request(history, keeping: 7))
        expect(
            base.requests.count == 1 && base.requests.first?.messages == request(history, keeping: 7).messages,
            "a chat that still fits costs no extra request and goes out as built")
        expect(outcome.events == script, "and shows no summary row")
        expect(!FileManager.default.fileExists(atPath: file.path), "and keeps no notes")
    }

    static func compactionSummarisesOnceThenReuses() async {
        let file = folder.appendingPathComponent("long.json")
        let history = chat(19)
        let built = request(history, keeping: 9)
        let base = ScriptedProvider(rounds: [
            [.text("notes v1"), .usage(AIUsage(inputTokens: 900, costUSD: 0.001)), .finished],
            [.text("answer"), .usage(AIUsage(inputTokens: 50, costUSD: 0.01)), .finished]
        ])
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let first = await run(
            AgentLoopProvider(base: base, toolset: tools, budget: .roomy, compaction: source(history, file: file)),
            built)
        let reach = AgentCompaction.coverage(of: history, dropped: 10)
        expect(base.requests.count == 2, "the first turn that drops messages asks for notes once")
        let fold = base.requests.first
        expect(
            fold?.instructions == AgentCompaction.instructions && fold?.tools.isEmpty == true
                && fold?.messages.first?.text.contains("User: m0 ") == true
                && fold?.messages.first?.text.contains("m\(reach) ") == false,
            "of the chat's own model, with no tools, over what it drops and a little more")
        let sent = base.requests.last?.messages ?? []
        expect(
            sent.count == 9 - (reach - 10)
                && sent.first?.text == AgentCompaction.preface("notes v1") + history[reach].text,
            "then the notes lead the turn, and what they cover is not sent twice")
        expect(
            Array(first.events.prefix(2)) == [
                .toolCall(id: AgentCompaction.markerID, origin: "Loop", title: AgentCompaction.markerTitle),
                .toolResult(id: AgentCompaction.markerID, isError: false)
            ],
            "a quiet row says earlier messages were summarised, got \(first.events)")
        expect(
            abs((lastCost(first.events) ?? 0) - 0.011) < 1e-12,
            "and the reply's cost includes the notes")
        let stored = AgentChatSummary.load(from: file)
        expect(
            stored?.text == "notes v1" && stored?.covered == reach
                && stored?.lastCoveredID == history[reach - 1].id,
            "the notes are kept with what they stand for")

        let grown = chat(2, after: history)
        let again = ScriptedProvider(rounds: [[.text("again"), .finished]])
        let second = await run(
            AgentLoopProvider(base: again, toolset: tools, budget: .roomy, compaction: source(grown, file: file)),
            request(grown, keeping: 9))
        let rowShown = second.events.contains { $0 == .toolResult(id: AgentCompaction.markerID, isError: false) }
        expect(again.requests.count == 1 && !rowShown, "the next turn reuses them with no request and no row")
        expect(
            again.requests.first?.messages.first?.text.hasPrefix(AgentCompaction.preface("notes v1")) == true,
            "and they still lead it")

        let longer = chat(12, after: grown)
        let extend = ScriptedProvider(rounds: [[.text("notes v2"), .finished], [.text("ok"), .finished]])
        _ = await run(
            AgentLoopProvider(base: extend, toolset: tools, budget: .roomy, compaction: source(longer, file: file)),
            request(longer, keeping: 9))
        let folded = extend.requests.first?.messages.first?.text ?? ""
        expect(
            folded.hasPrefix("<notes>\nnotes v1\n</notes>") && !folded.contains("User: m0 ")
                && folded.contains("m\(reach) "),
            "past them, one request folds only the newly dropped messages into the notes")
        expect(
            AgentChatSummary.load(from: file)?.text == "notes v2"
                && (AgentChatSummary.load(from: file)?.covered ?? 0) > reach,
            "which then stand for more of the chat")
    }

    static func aFailedSummaryLeavesTheTurnAsBuilt() async {
        let file = folder.appendingPathComponent("failed.json")
        let history = chat(19)
        let built = request(history, keeping: 9)
        let base = FailingFirstProvider(then: [[.text("answer"), .finished]])
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let outcome = await run(
            AgentLoopProvider(base: base, toolset: tools, budget: .roomy, compaction: source(history, file: file)),
            built)
        expect(
            outcome.failure == nil && outcome.events.contains(.toolResult(id: AgentCompaction.markerID, isError: true)),
            "a failed summary marks its row and the turn goes on")
        expect(base.requests.last?.messages == built.messages, "as it was built")
        expect(!FileManager.default.fileExists(atPath: file.path), "and keeps no notes")
    }

    static func stopReachesTheSummary() async {
        let file = folder.appendingPathComponent("stopped.json")
        let history = chat(19)
        let base = HangingProvider()
        let loop = AgentLoopProvider(
            base: base, toolset: toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }]), budget: .roomy,
            compaction: source(history, file: file))
        let consumer = Task {
            do {
                for try await _ in loop.stream(request(history, keeping: 9)) {}
            } catch {}
        }
        while base.requests == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        consumer.cancel()
        await consumer.value
        try? await Task.sleep(for: .milliseconds(200))
        expect(base.requests == 1, "Stop while the notes are made sends nothing more")
        expect(!FileManager.default.fileExists(atPath: file.path), "and keeps no notes")
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Fails its first request as a route that is down would, then replays a script.
final class FailingFirstProvider: AIProvider, @unchecked Sendable {
    private let script: ScriptedProvider
    private let lock = NSLock()
    private var seen: [AIRequest] = []

    init(then rounds: [[AIStreamEvent]]) {
        script = ScriptedProvider(rounds: rounds)
    }

    var requests: [AIRequest] { lock.withLock { seen } }

    func stream(_ request: AIRequest) -> AIProviderStream {
        let first = lock.withLock {
            seen.append(request)
            return seen.count == 1
        }
        guard first else { return script.stream(request) }
        return AIProviderStream { $0.finish(throwing: AIProviderError.responseFailed("down")) }
    }
}

/// Never answers, until whoever is listening goes away.
final class HangingProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var requests: Int { lock.withLock { count } }

    func stream(_ request: AIRequest) -> AIProviderStream {
        lock.withLock { count += 1 }
        return AIProviderStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(30))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Replays a script, then never answers, as a route that stalls on the next request.
final class ScriptThenHang: AIProvider, @unchecked Sendable {
    private let script: ScriptedProvider
    private let hang = HangingProvider()
    private let lock = NSLock()
    private let scripted: Int
    private var count = 0

    init(rounds: [[AIStreamEvent]]) {
        script = ScriptedProvider(rounds: rounds)
        scripted = rounds.count
    }

    var requests: Int { lock.withLock { count } }

    func stream(_ request: AIRequest) -> AIProviderStream {
        let replays = lock.withLock {
            count += 1
            return count <= scripted
        }
        return replays ? script.stream(request) : hang.stream(request)
    }
}

/// Counts the calls running at once, and the most there ever were.
final class Gauge: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var highest = 0

    var peak: Int { lock.withLock { highest } }

    /// How many were running, this one included, when it started.
    func hold(_ duration: Duration) async -> Int {
        let running = lock.withLock {
            current += 1
            highest = max(highest, current)
            return current
        }
        try? await Task.sleep(for: duration)
        lock.withLock { current -= 1 }
        return running
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

/// Offers named tools and answers each call with what `answer` returns.
struct FakeTools: AgentToolProvider {
    let names: [String]
    var risk: AgentToolRisk = .read
    var concurrent = false
    let answer: @Sendable (AIToolCall, AgentToolContext) async -> String

    init(
        names: [String], risk: AgentToolRisk = .read, concurrent: Bool = false,
        answer: @escaping @Sendable (AIToolCall, AgentToolContext) async -> String
    ) {
        self.names = names
        self.risk = risk
        self.concurrent = concurrent
        self.answer = answer
    }

    func specs(for turn: AgentTurn) -> [AgentToolSpec] {
        names.map { name in
            AgentToolSpec(
                tool: AITool(
                    name: name, description: "", parameters: .object([:]), origin: "Files",
                    title: name.uppercased()),
                family: nil, risk: risk, concurrent: concurrent)
        }
    }

    func run(_ call: AIToolCall, in context: AgentToolContext) async -> AIToolResult {
        AIToolResult(callID: call.id, content: await answer(call, context), isError: false)
    }
}

/// A call that sleeps until cancelled, remembering when it noticed.
final class Sleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var startedFlag = false
    private var noticedAt: ContinuousClock.Instant?

    var started: Bool { lock.withLock { startedFlag } }
    var noticed: ContinuousClock.Instant? { lock.withLock { noticedAt } }

    func sleep() async -> String {
        lock.withLock { startedFlag = true }
        try? await Task.sleep(for: .seconds(5))
        let now = ContinuousClock.now
        lock.withLock { noticedAt = now }
        return "woke"
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [AIStreamEvent] = []

    var events: [AIStreamEvent] { lock.withLock { seen } }

    func append(_ event: AIStreamEvent) {
        lock.withLock { seen.append(event) }
    }
}

/// A base route that replays one scripted round per request, as in ai-chat-test.
final class ScriptedProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var rounds: [[AIStreamEvent]]
    private var seen: [AIRequest] = []

    init(rounds: [[AIStreamEvent]]) {
        self.rounds = rounds
    }

    var requests: [AIRequest] {
        lock.withLock { seen }
    }

    func stream(_ request: AIRequest) -> AIProviderStream {
        let events: [AIStreamEvent] = lock.withLock {
            seen.append(request)
            return rounds.isEmpty ? [.finished] : rounds.removeFirst()
        }
        return AIProviderStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Stands in for the MCP coordinator: it records what it was asked and answers the same way.
final class RecordingInvoker: @unchecked Sendable {
    private let lock = NSLock()
    private let result: String
    private var received: [AIToolCall] = []

    init(result: String) {
        self.result = result
    }

    var calls: [AIToolCall] {
        lock.withLock { received }
    }

    func invoke(_ call: AIToolCall) async -> AIToolResult {
        lock.withLock { received.append(call) }
        return AIToolResult(callID: call.id, content: result, isError: false)
    }
}

// MARK: - Budgets and hand-overs

extension AgentLoopTests {
    static func drain(_ provider: any AIProvider, _ request: AIRequest) async {
        do {
            for try await _ in provider.stream(request) {}
        } catch {}
    }

    static func texts(_ events: [AIStreamEvent]) -> String {
        events.compactMap { event -> String? in
            if case .text(let text) = event { return text }
            return nil
        }.joined()
    }

    /// "If the task is simple there is nothing to do for long": one round, nothing added to it.
    static func aSimpleQuestionIsOneRound() async {
        let base = ScriptedProvider(rounds: [[.text("Paris."), .finished]])
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let outcome = await collect(
            AgentLoopProvider(base: base, toolset: tools, budget: AgentEffort.balanced.budget))
        expect(
            base.requests.count == 1 && outcome.events == [.text("Paris."), .finished],
            "a question the model answers at once is one request, passed through as it came")
        expect(
            base.requests.first?.messages == turn.messages,
            "and carries nothing of the budget: no note, no plan, no hand-over")
    }

    /// pi's and dsh's steering: a message sent mid-run joins the next request, never cutting a call.
    static func steeringIsReadAtTheNextStep() async {
        let steering = AgentSteering()
        let reader = FakeTools(names: ["fs_read"]) { _, _ in
            _ = steering.push("also check B")
            return "page"
        }
        let base = ScriptedProvider(rounds: [
            [call("c1")], [.text("A is fine."), .finished], [.text("B is fine too."), .finished]
        ])
        let outcome = await collect(
            AgentLoopProvider(
                base: base, toolset: toolset([reader]), budget: AgentEffort.balanced.budget, origin: "Loop",
                steering: steering))
        expect(outcome.failure == nil && outcome.events.last == .finished, "the steered run ends as usual")
        let second = base.requests.dropFirst().first?.messages.last
        expect(
            second?.role == .user && second?.text == "also check B",
            "a message sent during a call is the user's turn in the very next request")
        expect(
            outcome.events.contains(
                .toolCall(id: "tinycast-steer-1-0", origin: "Loop", title: AgentSteering.title("also check B"))),
            "and shows as a row of its own in the reply")
        let third = ScriptedProvider(rounds: [[.text("Done."), .finished], [.text("And that."), .finished]])
        let late = AgentSteering()
        _ = late.push("one more")
        let ended = await collect(
            AgentLoopProvider(
                base: third, toolset: toolset([reader]), budget: AgentEffort.balanced.budget, steering: late))
        expect(
            third.requests.count == 2 && ended.events.last == .finished,
            "a message waiting when the model meant to stop gets its turn before the run ends")
        expect(late.close().isEmpty && !late.push("too late"), "a closed run takes nothing more")
    }

    /// At four rounds of five the model is told to wrap up; after the fifth it hands over, tools off.
    static func aLongRunWrapsUpThenHandsOver() async {
        let ran = Heard()
        let reader = FakeTools(names: ["fs_read"]) { _, _ in
            ran.append(1)
            return "page"
        }
        let base = ScriptedProvider(
            rounds: Array(repeating: [call("c")], count: 5) + [[.text("Summary: done A, not B."), .finished]])
        let outcome = await collect(
            AgentLoopProvider(base: base, toolset: toolset([reader]), budget: AgentRunBudget(rounds: 5)))
        expect(outcome.failure == nil && outcome.events.last == .finished, "the run ends, it does not fail")
        expect(base.requests.count == 6 && ran.values.count == 5, "five rounds of calls, then one more request")
        let sent = base.requests.last?.messages ?? []
        let notes = sent.enumerated().filter { $0.element.role == .user }.dropFirst()
        expect(
            sent.compactMap(\.toolResult?.content) == Array(repeating: "page", count: 5),
            "the results stay as the tools gave them")
        expect(
            notes.count == 2
                && notes.first?.element.text.hasPrefix("[Run budget: 4 of 5 rounds used. Start wrapping up") == true
                && sent[(notes.first?.offset ?? 1) - 1].toolResult != nil,
            "the wrap-up is the user's turn after the fourth round's results, once, got \(notes.map(\.element.text))")
        expect(
            notes.last?.element.text.hasPrefix("[Run budget spent: 5 of 5 rounds used. Tools are off now") == true
                && notes.last?.offset == sent.count - 1,
            "and the hand-over the fifth's, where pi and dsh put theirs")
        expect(
            base.requests.last?.tools == base.requests.first?.tools && base.requests.allSatisfy { !$0.forbidsCalls },
            "the hand-over round still lists the tools and forbids nothing, so the cached prefix holds")
        expect(
            base.requests.dropLast().allSatisfy { request in
                base.requests.last.map { Array($0.messages.prefix(request.messages.count)) == request.messages }
                    ?? false
            },
            "and every request extends the one before it: nothing already sent is rewritten")
        expect(texts(outcome.events) == "Summary: done A, not B.", "its answer is the run's last word")
    }

    static func aHandOverThatSaysNothingStillHandsOver() async {
        let ran = Heard()
        let reader = FakeTools(names: ["fs_read", "update_plan"]) { _, _ in
            ran.append(1)
            return "ok"
        }
        let plan = #"{"plan":[{"step":"Read","status":"completed"},{"step":"Write","status":"pending"}]}"#
        let base = ScriptedProvider(rounds: [
            [call("p", "update_plan", plan)], [call("c")], [call("again")], [call("still")]
        ])
        let outcome = await collect(
            AgentLoopProvider(base: base, toolset: toolset([reader]), budget: AgentRunBudget(rounds: 2)))
        expect(
            outcome.failure == nil && ran.values.count == 2 && base.requests.count == 4,
            "a hand-over round that calls a tool runs nothing, nor does the one asked to call nothing")
        expect(
            texts(outcome.events)
                == "This run reached its limit before the agent summed up.\n\nPlan:\n✓ Read\n· Write\n",
            "and the reply still says where the run stopped, with its plan, got \(texts(outcome.events))")
    }

    /// A model that ignores the hand-over is answered "not run" and asked once more with calls off.
    static func anIgnoredHandOverIsEnforced() async {
        let ran = Heard()
        let reader = FakeTools(names: ["fs_read"]) { _, _ in
            ran.append(1)
            return "page"
        }
        let base = ScriptedProvider(rounds: [
            [call("c1")], [.text("Let me check one more source."), call("c2")],
            [.text("Found A; B is unchecked."), .finished]
        ])
        let outcome = await collect(
            AgentLoopProvider(base: base, toolset: toolset([reader]), budget: AgentRunBudget(rounds: 1)))
        let last = base.requests.last
        expect(
            outcome.failure == nil && ran.values.count == 1 && base.requests.count == 3,
            "the ignored hand-over's call never runs, and the round is asked once more")
        expect(
            last?.forbidsCalls == true && last?.tools == base.requests.first?.tools
                && base.requests.dropLast().allSatisfy { !$0.forbidsCalls },
            "that once with calls forbidden, its tools still listed")
        expect(
            last?.messages.last?.toolResult?.content == AgentBudgetPolicy.callsOff
                && outcome.events.contains(.toolResult(id: "c2", isError: true)),
            "the call is answered as not run, and its row closes as failed")
        expect(
            texts(outcome.events) == "Let me check one more source.Found A; B is unchecked.",
            "and the run ends on the model's own hand-over, got \(texts(outcome.events))")

        let stubborn = ScriptedProvider(rounds: [[call("c1")], [call("c2")], [.text("Checking."), call("c3")]])
        let kept = await collect(
            AgentLoopProvider(base: stubborn, toolset: toolset([reader]), budget: AgentRunBudget(rounds: 1)))
        expect(
            stubborn.requests.count == 3
                && texts(kept.events) == "Checking.\n\nThis run reached its limit before the agent summed up.",
            "a route that calls even then still ends with the limit said, got \(texts(kept.events))")

        let refusing = FlakyProvider(
            failures: [], failAt: [3: AIProviderError.responseFailed("tool_choice: only auto is supported")],
            then: [[call("c1")], [call("c2")]])
        let ended = await collect(
            AgentLoopProvider(
                base: refusing, toolset: toolset([reader]), budget: AgentRunBudget(rounds: 1), retry: quick))
        expect(
            ended.failure == nil && texts(ended.events) == "This run reached its limit before the agent summed up.",
            "and one that refuses to forbid calls ends the run all the same, got \(ended.failure ?? "")")
    }

    /// Upstream's loop fails at its wall; the fork's hands over instead.
    static func theHistoryWallHandsOver() async {
        let heavy = String(repeating: "z", count: AgentTurnBudget.historyBytes / 16)
        let base = ScriptedProvider(
            rounds: Array(repeating: [call("c", "fs_read", heavy)], count: 16) + [[.text("Partial.")]])
        let outcome = await collect(
            AgentLoopProvider(
                base: base, toolset: toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }]), budget: .roomy))
        expect(
            outcome.failure == nil && texts(outcome.events).hasSuffix("Partial.") && base.requests.count == 17,
            "a run at the history wall hands over rather than failing, got \(base.requests.count) "
                + "\(outcome.failure ?? "")")
    }

    static func anUnattendedRunHandsOverOnTime() async {
        let base = ScriptedProvider(rounds: [[call("c")], [.text("Out of time; did C.")]])
        let outcome = await collect(
            AgentLoopProvider(
                base: base, toolset: toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }]), budget: .roomy,
                clock: AgentRunClock(limit: .zero)))
        expect(
            base.requests.count == 2
                && base.requests.last?.messages.last?.text.contains("of 0 minutes used") == true
                && texts(outcome.events) == "Out of time; did C.",
            "past its time a run hands over after the round in hand")
    }

    /// A call still running at the run's end is stopped, so the hand-over comes before the watchdog.
    static func theClockStopsALongCall() async {
        let sleeper = Sleeper()
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in await sleeper.sleep() }])
        let base = ScriptedProvider(rounds: [[call("z1")], [.text("Ran out of time; did nothing."), .finished]])
        let started = ContinuousClock.now
        let outcome = await collect(
            AgentLoopProvider(
                base: base, toolset: tools, budget: .roomy,
                clock: AgentRunClock(limit: .milliseconds(300), from: started)))
        expect(
            outcome.failure == nil && ContinuousClock.now - started < .seconds(2)
                && base.requests.count == 2 && texts(outcome.events) == "Ran out of time; did nothing.",
            "the call is stopped at the run's end and the run hands over, got \(outcome.failure ?? "")")
        expect(
            base.requests.last?.messages.compactMap(\.toolResult?.content)
                == ["Not finished: the run's time ran out while this call was running."],
            "and the model is told the call never finished")
        let parent = AgentRunClock(limit: .seconds(600))
        let child = parent.child()
        expect(
            child.deadline == parent.deadline - AgentRunClock.childMargin && child.limit < parent.limit,
            "a sub-agent's clock ends a margin before its parent's")
        expect(
            AgentRunClock(limit: .seconds(60), from: .now - .seconds(120)).child().limit == .zero,
            "and one started past that point hands over after its first round")
    }

    static func anInterruptedReplyComesBack() async {
        let base = ScriptedProvider(rounds: [[.text("Picking up."), .finished]])
        let request = AIRequest(
            messages: [AIMessage(role: .user, text: "Do A and B."), AIMessage(role: .user, text: "Go on.")])
        let loop = AgentLoopProvider(
            base: base, toolset: toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }]), budget: .roomy,
            lead: AgentTurnLead(opening: "<now>", resuming: "Did A.\n\nThe network connection was lost."))
        await drain(loop, request)
        expect(
            base.requests.first?.messages == [
                AIMessage(role: .user, text: "Do A and B."),
                AIMessage(role: .assistant, text: "Did A.\n\nThe network connection was lost."),
                AIMessage(role: .user, text: "<now>\n\nGo on.")
            ],
            "the reply history left out goes back before the question, which the turn's facts lead")
        let answered = ScriptedProvider(rounds: [[.text("ok"), .finished]])
        let after = AIRequest(
            messages: [AIMessage(role: .user, text: "Q"), AIMessage(role: .assistant, text: "A"),
                AIMessage(role: .user, text: "Again")])
        let resumed = AgentLoopProvider(
            base: answered, toolset: toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }]), budget: .roomy,
            lead: AgentTurnLead(resuming: "stale"))
        await drain(resumed, after)
        expect(
            answered.requests.first?.messages == after.messages,
            "while a history that already alternates is left as it was")
    }

    static func effortsGrowAndStayWhereTheyWere() {
        let budgets = AgentEffort.allCases.map(\.budget)
        expect(
            zip(budgets, budgets.dropFirst()).allSatisfy { lower, higher in
                lower.rounds < higher.rounds && lower.resultBytes < higher.resultBytes
                    && lower.minutes < higher.minutes && lower.subAgents < higher.subAgents
            },
            "each effort allows more of everything than the one below it")
        expect(
            AgentEffort.balanced.budget.resultBytes == AgentTurnBudget.turnResultBytes,
            "and Balanced keeps the tool output a turn always had")
        var agent = AgentProfile(name: "A", directory: "/tmp")
        let plain = (try? JSONEncoder().encode(agent)).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
        expect(agent.effortLevel == .balanced && !plain.contains("effort"), "an untouched agent is Balanced, unwritten")
        agent.effort = .thorough
        let again = (try? JSONEncoder().encode(agent)).flatMap { try? JSONDecoder().decode(AgentProfile.self, from: $0) }
        expect(again?.effortLevel == .thorough, "a picked effort round-trips")
    }

    static let planned =
        #"{"plan":[{"step":"Read","status":"completed"},{"step":"Write","status":"in_progress"}]}"#

    /// One plan for the run: kept from `update_plan`, read back when it goes stale, said at the end.
    static func aPlanIsKeptReadBackAndReported() async {
        let tools = toolset([FakeTools(names: ["fs_read", "update_plan"]) { _, _ in "ok" }])
        let base = ScriptedProvider(
            rounds: [[call("p", "update_plan", planned)]] + Array(repeating: [call("c")], count: 7)
                + [[.text("Done."), .finished]])
        let outcome = await collect(AgentLoopProvider(base: base, toolset: tools, budget: AgentRunBudget(rounds: 10)))
        let results = base.requests.last?.messages.compactMap(\.toolResult?.content) ?? []
        expect(outcome.failure == nil && results.count == 8, "eight rounds of calls, then the answer")
        expect(
            results[6] == "ok\n\n[Plan: ✓ Read; → Write]" && results[1...5].allSatisfy { $0 == "ok" }
                && results[7] == "ok",
            "a plan not touched for six rounds is read back once, on the round's newest result, got \(results)")
        let wrapUp = base.requests.last?.messages.last
        expect(
            wrapUp?.role == .user && wrapUp?.text.contains("Start wrapping up") == true
                && wrapUp?.text.hasSuffix("\n[Plan: ✓ Read; → Write]") == true,
            "and the wrap-up carries it too")
    }

    static func aFailedRunSaysWhereItsPlanStood() async {
        let refused = AIProviderError.responseFailed("Invalid model")
        let base = FlakyProvider(
            failures: [], failAt: [3: refused],
            then: [[call("p", "update_plan", planned)], [call("c")], [.text("never")]])
        let tools = toolset([FakeTools(names: ["fs_read", "update_plan"]) { _, _ in "ok" }])
        let outcome = await collect(AgentLoopProvider(base: base, toolset: tools, budget: .roomy, retry: quick))
        expect(
            outcome.failure == "Invalid model"
                && texts(outcome.events) == "\n\nThe run stopped before the task was done.\n\nPlan:\n✓ Read\n→ Write\n",
            "a run that fails after working says where its plan stood, then fails, got \(texts(outcome.events))")
    }

    /// A round's sub-agents run at once, up to the batch's width, and no more than the run allows.
    static func subAgentsRunSideBySideWithinTheirAllowance() async {
        let children = SlowAnswerer()
        let delegate = AgentDelegateTools(
            base: children, toolset: childTools([FakeTools(names: ["fs_read"]) { _, _ in "x" }]), instructions: "",
            allowance: AgentSubAgentAllowance(2))
        let base = ScriptedProvider(rounds: [
            [delegateCall("d1", task: "A"), delegateCall("d2", task: "B"), delegateCall("d3", task: "C")],
            [.text("Merged."), .finished]
        ])
        let started = ContinuousClock.now
        let outcome = await collect(
            AgentLoopProvider(base: base, toolset: toolset([delegate], families: [.delegate]), budget: .roomy))
        let results = base.requests.last?.messages.compactMap(\.toolResult) ?? []
        expect(outcome.failure == nil && results.count == 3, "the round's three calls all answer")
        expect(
            children.gauge.peak == 2 && ContinuousClock.now - started < .milliseconds(390),
            "two children ran side by side, got a peak of \(children.gauge.peak)")
        let refused = results.filter(\.isError)
        expect(
            results.map(\.callID) == ["d1", "d2", "d3"] && results.filter { $0.content.hasPrefix("Found: ") }.count == 2
                && refused.count == 1
                && refused.first?.content.hasPrefix("This run may start no more sub-agents (2 used)") == true,
            "read in the order they were asked, and the one past the run's allowance refused, got \(results)")
    }
}

/// A child's route that takes a while and answers with its task, so overlap can be measured.
final class SlowAnswerer: AIProvider, @unchecked Sendable {
    let gauge = Gauge()

    func stream(_ request: AIRequest) -> AIProviderStream {
        let gauge = gauge
        let task = request.messages.last?.text ?? ""
        return AIProviderStream { continuation in
            let work = Task {
                _ = await gauge.hold(.milliseconds(200))
                continuation.yield(.text("Found: " + task))
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}
