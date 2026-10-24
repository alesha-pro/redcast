import Foundation
import os
import Synchronization

/// An agent's run: re-streams the turn until the model stops, or hands over at its budget.
struct AgentLoopProvider: AIProvider {
    private static let log = Logger(subsystem: "com.tinycast", category: "AgentLoop")

    /// Calls of one round that may run at once, so at most four fetches or four ripgreps.
    static let width = 4

    private let base: any AIProvider
    private let toolset: AgentToolset
    private let budget: AgentRunBudget
    /// An agent chat's; nil sends the turn as it was built, as upstream's loop does.
    private let compaction: AgentCompaction.Source?
    /// Each round's own output cap, so a long `write_file` is not cut at a route's short default.
    private let outputCap: Int?
    private let retry: AgentRetryPolicy
    /// Whose rows the loop's own notices are, as a retry's: the agent's name.
    private let origin: String
    private let lead: AgentTurnLead
    /// An unattended run's clock; a chat has someone to press Stop.
    private let clock: AgentRunClock?
    /// A sub-agent hands over to its parent, so its last words are the model's, never localized.
    private let answersAnAgent: Bool
    /// What the user sends mid-run, taken between rounds; nil where nobody can send.
    private let steering: AgentSteering?

    init(
        base: any AIProvider, toolset: AgentToolset, budget: AgentRunBudget,
        compaction: AgentCompaction.Source? = nil, outputCap: Int? = nil,
        retry: AgentRetryPolicy = .standard, origin: String = "", lead: AgentTurnLead = AgentTurnLead(),
        clock: AgentRunClock? = nil, answersAnAgent: Bool = false, steering: AgentSteering? = nil
    ) {
        self.base = base
        self.toolset = toolset
        self.budget = budget
        self.compaction = compaction
        self.outputCap = outputCap
        self.retry = retry
        self.origin = origin
        self.lead = lead
        self.clock = clock
        self.answersAnAgent = answersAnAgent
        self.steering = steering
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
        /// The route refused a reasoning field by name, so the rest of the run sends none.
        var dropsReasoning = false

        var said: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// What the run has kept between rounds: its plan, and how near its end it is.
    private struct Progress {
        var plan: [AgentPlan.Item]?
        var planRound = 0
        var warned = false
        var final = false
        /// The hand-over round called anyway, so the next one is asked to call nothing.
        var forced = false
        var worked = false
        /// The route refused a reasoning field, so no round of this run is sent one again.
        var bare = false
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

    /// A run that fails after real work says where its plan stood before the failure shows.
    private func run(
        _ request: AIRequest, into continuation: AIProviderStream.Continuation
    ) async throws {
        var progress = Progress()
        do {
            try await work(request, progress: &progress, into: continuation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if progress.worked, !answersAnAgent, let plan = progress.plan {
                continuation.yield(.text("\n\n" + Self.stopped + "\n\n" + AgentPlan.checklist(plan)))
            }
            throw error
        }
    }

    private func work(
        _ request: AIRequest, progress: inout Progress, into continuation: AIProviderStream.Continuation
    ) async throws {
        var (messages, billed) = try await compacted(request, into: continuation)
        messages = lead.led(messages)
        let spend = Spend()
        // Shown at once, so a Stop or a failure in the first round still leaves the notes billed.
        if let billed { continuation.yield(.usage(spend.reported(AIUsage(costUSD: billed)))) }
        var turnStart = messages.count
        var lastRound = turnStart
        var turn = AgentTurnBudget(allowance: budget.resultBytes)
        var rounds = 0
        var cap = outputCap.map(AgentOutputCap.init(tokens:))
        let signal: @Sendable (AgentToolSignal) -> Void = { signal in
            if case .spent(let cost) = signal { continuation.yield(.usage(spend.add(cost))) }
            if let event = signal.event { continuation.yield(event) }
        }
        while true {
            // A call that outlived Stop must not bill another round.
            try Task.checkCancellation()
            rounds += 1
            let round: Round
            do {
                let asked = request.continuing(with: messages, tools: toolset.tools)
                    .limited(cap.map(\.request) ?? request.outputCap, forbidsCalls: progress.forced)
                round = try await streamRound(
                    asked, number: rounds, billedBefore: billed, spend: spend, into: continuation)
            } catch where AgentRetryPolicy.isOverflow(error) {
                guard relieve(&messages, turnStart: &turnStart, lastRound: &lastRound, turn: &turn, &progress)
                else { throw error }
                rounds -= 1
                continue
            } catch where progress.forced && !(error is CancellationError) {
                // A route that will not forbid calls still lets the run end with what it has.
                continuation.yield(.text(handOver(progress.plan)))
                continuation.yield(.finished)
                return
            }
            if round.dropsCap { cap?.refuse() }
            if round.dropsReasoning, !progress.bare {
                progress.bare = true
                messages = messages.map(Self.bare)
            }
            let reasoning = progress.bare ? Self.bare(round.reasoning) : round.reasoning
            if let cost = round.cost { billed = (billed ?? 0) + cost }
            var raised = false
            if round.cutOff { raised = cap?.raise() ?? false }
            // A reply the limit cut before it said a word is asked again, once, with room to answer.
            if raised, round.calls.isEmpty, !round.said {
                rounds -= 1
                continue
            }
            guard !round.calls.isEmpty, !progress.final else {
                if progress.final, !round.calls.isEmpty, !progress.forced {
                    progress.forced = true
                    refuseCalls(of: round, reasoning: reasoning, in: &messages, into: continuation)
                    continue
                }
                // pi's rule: a message sent while the model answered gets its turn before the run ends.
                if !progress.final, round.calls.isEmpty, let steer = steered(round: rounds, into: continuation) {
                    if round.said { continuation.yield(.text("\n\n")) }
                    messages.append(AIMessage(role: .assistant, text: round.text, reasoning: reasoning))
                    messages.append(steer)
                    continue
                }
                if let closing = closing(round, progress) { continuation.yield(.text(closing)) }
                continuation.yield(.finished)
                return
            }
            let roundStart = messages.count
            lastRound = roundStart
            messages.append(
                AIMessage(role: .assistant, text: round.text, toolCalls: round.calls, reasoning: reasoning))
            turn.carry(round.text, calls: round.calls, reasoning: reasoning)
            let concurrent = round.calls.map { toolset.isConcurrent($0.name) }
            for batch in AgentBatchPolicy.batches(concurrent, width: Self.width) {
                try Task.checkCancellation()
                let calls = Array(round.calls[batch])
                for call in calls { continuation.yield(row(for: call)) }
                let results =
                    round.cutOff
                    ? refused(calls, budget: &turn, into: continuation)
                    : await run(calls, signal: signal, budget: &turn, into: continuation)
                messages += results.map { AIMessage(role: .tool, text: "", toolResult: $0) }
                if let spent = spend.take() { billed = (billed ?? 0) + spent }
                track(calls, results, round: rounds, in: &progress)
            }
            progress.worked = true
            turn.release(AgentTurnBudget.elide(&messages, turnStart: turnStart, keepFrom: roundStart))
            let usage = AgentBudgetPolicy.Usage(
                rounds: rounds, resultBytes: turn.spent, carried: turn.carried,
                elapsed: clock?.elapsed ?? .zero)
            let step = AgentBudgetPolicy.step(
                after: usage, of: budget, timeLimit: clock?.limit, warned: progress.warned)
            // A wrap-up or a hand-over is the user's turn after the results, as pi and dsh send theirs.
            switch step {
            case .handOver(let spent):
                progress.final = true
                messages.append(
                    AIMessage(role: .user, text: AgentBudgetPolicy.handOver(spent, plan: progress.plan)))
            case .wrapUp(let used):
                progress.warned = true
                progress.planRound = rounds
                messages.append(
                    AIMessage(role: .user, text: AgentBudgetPolicy.wrapUp(used, plan: progress.plan)))
            case .go:
                guard progress.plan != nil, rounds - progress.planRound >= AgentBudgetPolicy.reciteEvery
                else { break }
                progress.planRound = rounds
                Self.note(AgentBudgetPolicy.recital(progress.plan), on: &messages)
            }
            // The step boundary: whatever the user sent meanwhile is read before the next request.
            if !progress.final, let steer = steered(round: rounds, into: continuation) { messages.append(steer) }
        }
    }

    /// The user's messages sent mid-run, shown as rows and joined into one turn of theirs.
    private func steered(round: Int, into continuation: AIProviderStream.Continuation) -> AIMessage? {
        guard let texts = steering?.take(), !texts.isEmpty else { return nil }
        for (index, text) in texts.enumerated() {
            let id = "tinycast-steer-\(round)-\(index)"
            continuation.yield(.toolCall(id: id, origin: origin, title: AgentSteering.title(text)))
            continuation.yield(.toolResult(id: id, isError: false))
        }
        return AIMessage(role: .user, text: texts.joined(separator: "\n\n"))
    }

    /// dsh's rule, a step per overflow: older results and reasoning, older history, then a hand-over.
    private func relieve(
        _ messages: inout [AIMessage], turnStart: inout Int, lastRound: inout Int,
        turn: inout AgentTurnBudget, _ progress: inout Progress
    ) -> Bool {
        let older = AgentTurnBudget.elide(
            &messages, turnStart: turnStart, keepFrom: lastRound, above: 0, to: 0)
        turn.release(older)
        guard older == 0 else { return true }
        if AgentTurnBudget.dropHistory(&messages, turnStart: &turnStart, keepFrom: &lastRound) { return true }
        guard progress.worked, !progress.final else { return false }
        turn.release(
            AgentTurnBudget.elide(&messages, turnStart: turnStart, keepFrom: messages.count, above: 0, to: 0))
        progress.final = true
        let note = AgentBudgetPolicy.handOver(AgentBudgetPolicy.windowFull, plan: progress.plan)
        messages.append(AIMessage(role: .user, text: note))
        return true
    }

    /// The hand-over round's calls run nothing: each is answered so, and the round is asked again.
    private func refuseCalls(
        of round: Round, reasoning: AIReasoningReplay?, in messages: inout [AIMessage],
        into continuation: AIProviderStream.Continuation
    ) {
        messages.append(
            AIMessage(role: .assistant, text: round.text, toolCalls: round.calls, reasoning: reasoning))
        for call in round.calls {
            continuation.yield(row(for: call))
            messages.append(
                AIMessage(role: .tool, text: "", toolResult: .failure(call.id, AgentBudgetPolicy.callsOff)))
            continuation.yield(.toolResult(id: call.id, isError: true))
        }
    }

    private func row(for call: AIToolCall) -> AIStreamEvent {
        let tool = toolset.tools.first { $0.name == call.name }
        // A provider's own title names the call already; any other row shows what it was given.
        let title =
            toolset.title(for: call)
            ?? AgentCallSummary.title(tool?.title ?? call.name, arguments: call.arguments)
        return .toolCall(id: call.id, origin: tool?.origin ?? "", title: title)
    }

    /// What the reply still needs after its last round: a hand-over it owed, or where the limit cut it.
    private func closing(_ round: Round, _ progress: Progress) -> String? {
        let owed = progress.final && (!round.said || !round.calls.isEmpty)
        guard owed || round.cutOff && round.calls.isEmpty else { return nil }
        let line = owed ? handOver(progress.plan) : round.said ? cutShort : cutSilent
        return round.said ? "\n\n" + line : line
    }

    /// A plan the model sent and the toolset took is the run's plan from now on.
    private func track(
        _ calls: [AIToolCall], _ results: [AIToolResult], round: Int, in progress: inout Progress
    ) {
        for (call, result) in zip(calls, results) where call.name == AgentPlan.name && !result.isError {
            guard let items = AgentPlan.items(in: call.arguments) else { continue }
            progress.plan = items
            progress.planRound = round
        }
    }

    /// The model's notes ride the round's last result, added before it is ever sent: no prefix moves.
    private static func note(_ text: String, on messages: inout [AIMessage]) {
        guard !text.isEmpty, let last = messages.indices.last, let result = messages[last].toolResult
        else { return }
        let noted = AIToolResult(
            callID: result.callID, content: result.content + "\n\n" + text, isError: result.isError)
        messages[last] = AIMessage(role: .tool, text: messages[last].text, toolResult: noted)
    }

    /// What a hand-over round that said nothing, or still called, leaves in the reply.
    private func handOver(_ plan: [AgentPlan.Item]?) -> String {
        let checklist = plan.map { "\n\n" + AgentPlan.checklist($0) } ?? ""
        guard !answersAnAgent else {
            return "The sub-task's budget ran out before it wrote an answer." + checklist
        }
        return String(localized: "This run reached its limit before the agent summed up.") + checklist
    }

    private static let stopped = String(localized: "The run stopped before the task was done.")

    private var cutShort: String {
        answersAnAgent
            ? "[The answer was cut off at the output limit.]"
            : String(localized: "The reply was cut off at the model's output limit.")
    }

    private var cutSilent: String {
        answersAnAgent
            ? "The sub-task reached its output limit before it answered."
            : String(localized: "The model reached its output limit before it answered.")
    }

    /// What a call the run's clock stopped is answered, so the model knows it never finished.
    private static let unfinished = "Not finished: the run's time ran out while this call was running."

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
        let deadline = clock?.deadline
        return await withTaskGroup(of: (Int, AIToolResult, Bool)?.self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    let result = await toolset.run(call, signal: signal)
                    return (index, result, Task.isCancelled)
                }
            }
            // The run's clock stops calls still running at its end, so the hand-over still comes.
            if let deadline {
                group.addTask {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    return nil
                }
            }
            var results = [AIToolResult?](repeating: nil, count: calls.count)
            var left = calls.count
            var late = false
            while left > 0, let next = await group.next() {
                guard case let (index, raw, stopped)? = next else {
                    late = !Task.isCancelled
                    group.cancelAll()
                    continue
                }
                let result = budget.admit(stopped && late ? .failure(raw.callID, Self.unfinished) : raw)
                continuation.yield(.toolResult(id: calls[index].id, isError: result.isError))
                results[index] = result
                left -= 1
            }
            group.cancelAll()
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
        var dropsReasoning = false
        var retries = 0
        while true {
            var round = Round()
            do {
                try await stream(request, billedBefore: sum(billedBefore, failedCost), spend: spend,
                    into: &round, continuation)
                round.cost = sum(failedCost, round.cost)
                round.dropsCap = dropsCap
                round.dropsReasoning = dropsReasoning
                return round
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // What a failed attempt reported it spent is spent; the next is billed on top of it.
                failedCost = sum(failedCost, round.cost)
                // An answer already on screen would show twice, so a failure after one stands.
                guard round.text.isEmpty else { throw error }
                if request.outputCap != nil, AgentRetryPolicy.refusesOutputCap(error) {
                    request = request.limited(nil, forbidsCalls: request.forbidsCalls)
                    dropsCap = true
                    continue
                }
                if !dropsReasoning, AgentRetryPolicy.refusesReasoning(error),
                    request.messages.contains(where: { Self.bare($0) != $0 })
                {
                    request = request.continuing(with: request.messages.map(Self.bare), tools: request.tools)
                    dropsReasoning = true
                    continue
                }
                retries += 1
                let reason = AgentRetryPolicy.reason(error)
                guard let wait = retry.delay(before: retries, after: error, random: .random(in: 0...1))
                else {
                    Self.log.error("round \(number) failed: \(reason, privacy: .public)")
                    throw error
                }
                let delay = String(describing: wait)
                Self.log.notice(
                    "round \(number) retry \(retries) in \(delay, privacy: .public): \(reason, privacy: .public)")
                let id = "tinycast-retry-\(number)-\(retries)"
                // The row says what failed, so a wait reads as a provider's trouble, not a hang.
                continuation.yield(
                    .toolCall(
                        id: id, origin: origin,
                        title: AgentRetryPolicy.title(retries, of: retry.attempts, reason: reason)))
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

    /// What a route that refused the reasoning fields is still sent: Claude's blocks, a call's stamp.
    private static func bare(_ reasoning: AIReasoningReplay?) -> AIReasoningReplay? {
        guard let form = reasoning?.form, form != .blocks else { return reasoning }
        return nil
    }

    private static func bare(_ message: AIMessage) -> AIMessage {
        guard message.reasoning != bare(message.reasoning) else { return message }
        return AIMessage(
            role: message.role, text: message.text, images: message.images, documents: message.documents,
            audio: message.audio, toolCalls: message.toolCalls, toolResult: message.toolResult)
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
