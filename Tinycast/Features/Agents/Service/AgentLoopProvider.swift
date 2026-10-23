import Foundation
import Synchronization

/// An agent's turn: re-streams it until the model stops calling tools or a cap ends it.
struct AgentLoopProvider: AIProvider {
    /// Calls of one round that may run at once, so at most four fetches or four ripgreps.
    static let width = 4

    private let base: any AIProvider
    private let toolset: AgentToolset
    private let maxRounds: Int?
    /// An agent chat's; nil sends the turn as it was built, as upstream's loop does.
    private let compaction: AgentCompaction.Source?
    /// Each round's own output cap, so a long `write_file` is not cut at a route's 4K default.
    private let outputCap: Int?
    private let retry: AgentRetryPolicy
    /// Whose rows the loop's own notices are, as a retry's: the agent's name.
    private let origin: String

    init(
        base: any AIProvider, toolset: AgentToolset, maxRounds: Int?,
        compaction: AgentCompaction.Source? = nil, outputCap: Int? = nil,
        retry: AgentRetryPolicy = .standard, origin: String = ""
    ) {
        self.base = base
        self.toolset = toolset
        self.maxRounds = maxRounds
        self.compaction = compaction
        self.outputCap = outputCap
        self.retry = retry
        self.origin = origin
    }

    /// One reply of the model: its text, the calls it made and what came with them.
    private struct Round {
        var text = ""
        var calls: [AIToolCall] = []
        var cost: Double?
        var reasoning: AIReasoningReplay?
        var cutOff = false
        /// The route refused the round's output cap, so the rest of the turn goes without one.
        var dropsCap = false
    }

    func stream(_ request: AIRequest) -> AIProviderStream {
        AIProviderStream { continuation in
            let task = Task.detached {
                do {
                    try await run(request, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: AIRequest, into continuation: AIProviderStream.Continuation
    ) async throws {
        var (messages, billed) = try await compacted(request, into: continuation)
        let spend = Spend()
        // Shown at once, so a Stop or a failure in the first round still leaves the notes billed.
        if let billed { continuation.yield(.usage(spend.reported(AIUsage(costUSD: billed)))) }
        var turnStart = messages.count
        var lastRound = turnStart
        var budget = AgentTurnBudget()
        var rounds = 0
        var cap = outputCap ?? request.outputCap
        var relieved = false
        let signal: @Sendable (AgentToolSignal) -> Void = { signal in
            if case .spent(let cost) = signal { continuation.yield(.usage(spend.add(cost))) }
            if let event = signal.event { continuation.yield(event) }
        }
        while maxRounds.map({ rounds < $0 }) ?? (budget.carried < AgentTurnBudget.historyBytes) {
            // A call that outlived Stop must not bill another round.
            try Task.checkCancellation()
            rounds += 1
            let round: Round
            do {
                round = try await streamRound(
                    request.continuing(with: messages, tools: toolset.tools).capped(at: cap),
                    number: rounds, billedBefore: billed, spend: spend, into: continuation)
            } catch where AgentRetryPolicy.isOverflow(error) && !relieved {
                // dsh's rule: a window that overflows is shed once, then the round is asked again.
                relieved = true
                let elided = AgentTurnBudget.elide(
                    &messages, turnStart: turnStart, keepFrom: lastRound, above: 0, to: 0)
                guard elided > 0 || AgentTurnBudget.dropHistory(&messages, turnStart: &turnStart, keepFrom: &lastRound)
                else { throw error }
                budget.release(elided)
                rounds -= 1
                continue
            }
            if round.dropsCap { cap = nil }
            if let cost = round.cost { billed = (billed ?? 0) + cost }
            guard !round.calls.isEmpty else {
                continuation.yield(.finished)
                return
            }
            let roundStart = messages.count
            lastRound = roundStart
            messages.append(
                AIMessage(
                    role: .assistant, text: round.text, toolCalls: round.calls, reasoning: round.reasoning))
            budget.carry(round.text, calls: round.calls)
            let concurrent = round.calls.map { toolset.isConcurrent($0.name) }
            for batch in AgentBatchPolicy.batches(concurrent, width: Self.width) {
                try Task.checkCancellation()
                let calls = Array(round.calls[batch])
                for call in calls {
                    let tool = toolset.tools.first { $0.name == call.name }
                    let title = toolset.title(for: call) ?? tool?.title ?? call.name
                    continuation.yield(.toolCall(id: call.id, origin: tool?.origin ?? "", title: title))
                }
                let results =
                    round.cutOff
                    ? refused(calls, budget: &budget, into: continuation)
                    : await run(calls, signal: signal, budget: &budget, into: continuation)
                messages += results.map { AIMessage(role: .tool, text: "", toolResult: $0) }
                if let spent = spend.take() { billed = (billed ?? 0) + spent }
            }
            budget.release(
                AgentTurnBudget.elide(&messages, turnStart: turnStart, keepFrom: roundStart))
        }
        throw AIProviderError.responseFailed(
            String(localized: "Stopped after \(rounds) rounds of tool calls."))
    }

    /// The turn with notes on what the budget dropped leading it, and what making them cost.
    private func compacted(
        _ request: AIRequest, into continuation: AIProviderStream.Continuation
    ) async throws -> (messages: [AIMessage], cost: Double?) {
        guard let compaction else { return (request.messages, nil) }
        let history = await compaction.history()
        guard let dropped = AgentCompaction.dropped(from: history, sent: request.messages), dropped > 0
        else { return (request.messages, nil) }
        let stored = AgentChatSummary.load(from: compaction.url)
        switch AgentCompaction.plan(history: history, dropped: dropped, summary: stored) {
        case .reuse(let summary):
            return (AgentCompaction.messages(request.messages, dropped: dropped, summary: summary), nil)
        case .extend(let from, let to, let previous):
            let id = AgentCompaction.markerID
            continuation.yield(
                .toolCall(id: id, origin: compaction.origin, title: AgentCompaction.markerTitle))
            let made = try await summarise(
                AgentCompaction.request(previous: previous, slice: history[from..<to]))
            let summary = made.text.flatMap { AgentCompaction.summary($0, covering: to, of: history) }
            continuation.yield(.toolResult(id: id, isError: summary == nil))
            guard let summary else { return (request.messages, made.cost) }
            try? summary.write(to: compaction.url)
            return (AgentCompaction.messages(request.messages, dropped: dropped, summary: summary), made.cost)
        }
    }

    /// The chat's own model, asked once with no tools; a failure leaves the turn as it was built.
    private func summarise(_ request: AIRequest) async throws -> (text: String?, cost: Double?) {
        var text = ""
        var cost: Double?
        do {
            for try await event in base.stream(request) {
                try Task.checkCancellation()
                switch event {
                case .text(let delta): text += delta
                case .usage(let usage): cost = usage.costUSD ?? cost
                default: break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (nil, cost)
        }
        try Task.checkCancellation()
        return (text, cost)
    }

    /// A reply the output cap cut may have cut its calls' arguments too: none of them runs.
    private func refused(
        _ calls: [AIToolCall], budget: inout AgentTurnBudget,
        into continuation: AIProviderStream.Continuation
    ) -> [AIToolResult] {
        calls.map { call in
            let result = budget.admit(.cutOff(call))
            continuation.yield(.toolResult(id: call.id, isError: true))
            return result
        }
    }

    /// A batch's admitted results in call order; each row closes as its own call ends.
    private func run(
        _ calls: [AIToolCall], signal: @escaping @Sendable (AgentToolSignal) -> Void,
        budget: inout AgentTurnBudget, into continuation: AIProviderStream.Continuation
    ) async -> [AIToolResult] {
        let toolset = toolset
        return await withTaskGroup(of: (Int, AIToolResult).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask { (index, await toolset.run(call, signal: signal)) }
            }
            var results = [AIToolResult?](repeating: nil, count: calls.count)
            for await (index, raw) in group {
                let result = budget.admit(raw)
                continuation.yield(.toolResult(id: calls[index].id, isError: result.isError))
                results[index] = result
            }
            return results.compactMap { $0 }
        }
    }

    /// A round, asked again while it fails before answering and the failure may pass.
    private func streamRound(
        _ request: AIRequest, number: Int, billedBefore: Double?, spend: Spend,
        into continuation: AIProviderStream.Continuation
    ) async throws -> Round {
        var request = request
        var failedCost: Double?
        var dropsCap = false
        var retries = 0
        while true {
            var round = Round()
            do {
                try await stream(request, billedBefore: sum(billedBefore, failedCost), spend: spend,
                    into: &round, continuation)
                round.cost = sum(failedCost, round.cost)
                round.dropsCap = dropsCap
                return round
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // What a failed attempt reported it spent is spent; the next is billed on top of it.
                failedCost = sum(failedCost, round.cost)
                // An answer already on screen would show twice, so a failure after one stands.
                guard round.text.isEmpty else { throw error }
                if request.outputCap != nil, AgentRetryPolicy.refusesOutputCap(error) {
                    request = request.capped(at: nil)
                    dropsCap = true
                    continue
                }
                retries += 1
                guard let wait = retry.delay(before: retries, after: error, random: .random(in: 0...1))
                else { throw error }
                let id = "tinycast-retry-\(number)-\(retries)"
                continuation.yield(
                    .toolCall(
                        id: id, origin: origin, title: AgentRetryPolicy.title(retries, of: retry.attempts)))
                try await Task.sleep(for: wait)
                continuation.yield(.toolResult(id: id, isError: false))
            }
        }
    }

    /// One pass over the base route: text flows straight to the transcript, calls are collected.
    private func stream(
        _ request: AIRequest, billedBefore: Double?, spend: Spend, into round: inout Round,
        _ continuation: AIProviderStream.Continuation
    ) async throws {
        for try await event in base.stream(request) {
            try Task.checkCancellation()
            switch event {
            case .text(let delta):
                round.text += delta
                continuation.yield(event)
            case .usage(var usage):
                round.cost = usage.costUSD ?? round.cost
                // A turn is billed for every round; the reply's cost is the turn's, not its last.
                if let billedBefore { usage.costUSD = billedBefore + (usage.costUSD ?? 0) }
                continuation.yield(.usage(spend.reported(usage)))
            case .toolCallRequested(let call):
                round.calls.append(call)
            case .reasoningReplay(let replay):
                round.reasoning = replay
                continuation.yield(event)
            case .outputLimit:
                round.cutOff = true
            // `.finished` is the loop's to send, once the model has stopped asking for tools.
            case .finished:
                break
            default:
                continuation.yield(event)
            }
        }
    }

    private func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard lhs != nil || rhs != nil else { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }
}

/// The usage the reply shows and what calls spent since the last take; calls share it, so it locks.
private final class Spend: Sendable {
    private let state = Mutex((unbilled: 0.0, shown: AIUsage?.none))

    /// The usage the reply now shows, which a call's spend then raises.
    func reported(_ usage: AIUsage) -> AIUsage {
        state.withLock { $0.shown = usage }
        return usage
    }

    /// Shown as it lands: a capped run must hear a sub-agent's rounds before its parent's next one.
    func add(_ cost: Double) -> AIUsage {
        state.withLock { state in
            state.unbilled += cost
            var usage = state.shown ?? AIUsage()
            usage.costUSD = (usage.costUSD ?? 0) + cost
            state.shown = usage
            return usage
        }
    }

    /// The sum since the last take, nil when nothing was spent.
    func take() -> Double? {
        state.withLock { state in
            defer { state.unbilled = 0 }
            return state.unbilled > 0 ? state.unbilled : nil
        }
    }
}
