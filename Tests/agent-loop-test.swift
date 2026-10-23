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
        await anAgentTurnCostsEveryRound()
        await theSpendMeterHearsEachRoundsCost()
        await aLongTurnElidesInsteadOfStopping()
        await callsThatMayShareARoundDo()
        await aCallThatMayNotRunsAlone()
        await aRoundIsNeverWiderThanFour()
        theDelegateToolOnlyReadsAndRunsAlone()
        await aSubAgentAnswersInsideItsParentsTurn()
        await aSubAgentIsBounded()
        await stopReachesASubAgent()
        await aSubAgentsSpendIsHeardAsItLands()
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
        let fork = await collect(AgentLoopProvider(base: forkBase, toolset: tools, maxRounds: maxRounds))
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
        await differential("the round cap", rounds: forever, maxRounds: 3)
        await differential(
            "a 40 KB result", rounds: [[call("c1")], [.text("ok"), .finished]], maxRounds: 25
        ) { _ in String(repeating: "x", count: 40 * 1_024) }
        await differential(
            "unlimited rounds", rounds: forever + [[.text("done"), .finished]], maxRounds: nil)
        let heavy = String(repeating: "z", count: AgentTurnBudget.historyBytes / 16)
        await differential(
            "the history wall", rounds: Array(repeating: [call("c", "fs_read", heavy)], count: 40),
            maxRounds: nil)
        await differential(
            "reasoning, searches and usage", rounds: [
                [
                    .thinking, .reasoning("plan"), .usage(AIUsage(inputTokens: 10, outputTokens: 2)),
                    call("c1")
                ],
                [.searching("q"), .searched("q"), .text("ok"), .usage(AIUsage(inputTokens: 20)), .finished]
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
        let events = await collect(AgentLoopProvider(base: base, toolset: tools, maxRounds: 25)).events
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
            AgentLoopProvider(base: base, toolset: toolset([searcher]), maxRounds: 25)
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
        let loop = AgentLoopProvider(base: base, toolset: tools, maxRounds: nil)
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
        let events = await collect(AgentLoopProvider(base: base, toolset: tools, maxRounds: 25)).events
        expect(base.requests.count == 1, "a turn that calls nothing is one request")
        expect(base.requests.first?.tools == tools.tools, "armed with the turn's tools")
        expect(events == script, "and its events pass through unchanged")
    }

    static func anAgentTurnCostsEveryRound() async {
        let base = ScriptedProvider(rounds: [
            [.usage(AIUsage(inputTokens: 10, costUSD: 0.01)), call("c1")],
            [.text("ok"), .usage(AIUsage(inputTokens: 30, costUSD: 0.02)), .finished]
        ])
        let tools = toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }])
        let events = await collect(AgentLoopProvider(base: base, toolset: tools, maxRounds: 25)).events
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
            AgentLoopProvider(base: ScriptedProvider(rounds: rounds), toolset: tools, maxRounds: 25)).events
        let heard = Heard()
        let metered = await collect(
            AgentSpendMeter(
                base: AgentLoopProvider(base: ScriptedProvider(rounds: rounds), toolset: tools, maxRounds: 25)
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
        let outcome = await collect(AgentLoopProvider(base: base, toolset: toolset([page]), maxRounds: 25))
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
        let events = await collect(AgentLoopProvider(base: base, toolset: toolset([reader]), maxRounds: 25))
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
            AgentLoopProvider(base: base, toolset: toolset([reader, writer]), maxRounds: 25)
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
        _ = await collect(AgentLoopProvider(base: base, toolset: toolset([reader]), maxRounds: 25))
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

    static func theDelegateToolOnlyReadsAndRunsAlone() {
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
                && specs.first?.risk == .read && specs.first?.concurrent == false,
            "delegate is the Sub-agents family's, changes nothing itself, and one child runs at a time")
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
        let outcome = await collect(AgentLoopProvider(base: base, toolset: parent, maxRounds: 25))
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
            stopped.isError && stopped.content.contains("Stopped after 12 rounds")
                && looping.requests.count == AgentDelegateTools.maxRounds,
            "a child that keeps calling stops at its own round cap, got \(stopped.content)")

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
        let loop = AgentLoopProvider(base: base, toolset: parent, maxRounds: nil)
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
        return AgentLoopProvider(base: base, toolset: toolset([delegate], families: [.delegate]), maxRounds: 25)
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
        expect(
            pair.requests.count == 4 && cents(both.values) == [0.01, 0.51, 0.76, 0.77],
            "two sub-agents of one round are heard one at a time, got \(both.values)")
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
            AgentLoopProvider(base: base, toolset: tools, maxRounds: 25, compaction: source(history, file: file)),
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
            AgentLoopProvider(base: base, toolset: tools, maxRounds: 25, compaction: source(history, file: file)),
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
            AgentLoopProvider(base: again, toolset: tools, maxRounds: 25, compaction: source(grown, file: file)),
            request(grown, keeping: 9))
        let rowShown = second.events.contains { $0 == .toolResult(id: AgentCompaction.markerID, isError: false) }
        expect(again.requests.count == 1 && !rowShown, "the next turn reuses them with no request and no row")
        expect(
            again.requests.first?.messages.first?.text.hasPrefix(AgentCompaction.preface("notes v1")) == true,
            "and they still lead it")

        let longer = chat(12, after: grown)
        let extend = ScriptedProvider(rounds: [[.text("notes v2"), .finished], [.text("ok"), .finished]])
        _ = await run(
            AgentLoopProvider(base: extend, toolset: tools, maxRounds: 25, compaction: source(longer, file: file)),
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
            AgentLoopProvider(base: base, toolset: tools, maxRounds: 25, compaction: source(history, file: file)),
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
            base: base, toolset: toolset([FakeTools(names: ["fs_read"]) { _, _ in "x" }]), maxRounds: 25,
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
