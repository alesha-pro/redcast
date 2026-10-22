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
        _ providers: [any AgentToolProvider], mcp invoker: RecordingInvoker = RecordingInvoker(result: "mcp")
    ) -> AgentToolset {
        AgentToolset(
            turn: AgentTurn(
                profile: AgentProfile(name: "Loop", directory: "/tmp"), skills: [],
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
