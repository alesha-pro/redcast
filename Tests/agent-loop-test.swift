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
            mcpTools: [AITool(name: "srv__read", description: "", parameters: .object([:]), origin: "Server")],
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
        let tools = toolset([FakeTools(names: ["fs_read", "fs_list"]) { call, _ in answer(call) }], mcp: invoker)
        let upstreamBase = ScriptedProvider(rounds: rounds)
        let forkBase = ScriptedProvider(rounds: rounds)
        let upstream = await collect(
            AIToolLoopProvider(base: upstreamBase, tools: tools.tools, maxRounds: maxRounds) { call in
                await tools.run(call, signal: { _ in })
            })
        let fork = await collect(AgentLoopProvider(base: forkBase, toolset: tools, maxRounds: maxRounds))
        expect(fork.events == upstream.events, "\(name): both loops emit the same events")
        expect(fork.failure == upstream.failure, "\(name): and end the same way, \(fork.failure ?? "finished")")
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
            "the turn budget used up",
            rounds: [(1...5).map { call("c\($0)") }, [call("c6")], [.text("ok"), .finished]],
            maxRounds: 25
        ) { _ in String(repeating: "y", count: 30 * 1_024) }
        await differential(
            "unlimited rounds", rounds: forever + [[.text("done"), .finished]], maxRounds: nil)
        let heavy = String(repeating: "z", count: AgentTurnBudget.historyBytes / 16)
        await differential(
            "the history wall", rounds: Array(repeating: [call("c", "fs_read", heavy)], count: 40),
            maxRounds: nil)
        await differential(
            "reasoning, searches and usage", rounds: [
                [.thinking, .reasoning("plan"), .usage(AIUsage(inputTokens: 10, outputTokens: 2)), call("c1")],
                [.searching("q"), .searched("q"), .text("ok"), .usage(AIUsage(inputTokens: 20)), .finished]
            ], maxRounds: 25)
    }

    static func constantsMatchUpstream() {
        expect(
            AgentTurnBudget.resultBytes == AIToolLoopProvider.maxResultBytes,
            "a result is cut where upstream cuts it")
        expect(
            AgentTurnBudget.turnResultBytes == AIToolLoopProvider.maxTurnResultBytes,
            "a turn's results stop where upstream's do")
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
