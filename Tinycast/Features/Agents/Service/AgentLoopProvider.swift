import Foundation

/// An agent's turn: re-streams it until the model stops calling tools or a cap ends it.
struct AgentLoopProvider: AIProvider {
    /// Calls of one round that may run at once, so at most four fetches or four ripgreps.
    static let width = 4

    private let base: any AIProvider
    private let toolset: AgentToolset
    private let maxRounds: Int?

    init(base: any AIProvider, toolset: AgentToolset, maxRounds: Int?) {
        self.base = base
        self.toolset = toolset
        self.maxRounds = maxRounds
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
        var messages = request.messages
        var budget = AgentTurnBudget()
        var rounds = 0
        let signal: @Sendable (AgentToolSignal) -> Void = { continuation.yield($0.event) }
        while maxRounds.map({ rounds < $0 }) ?? (budget.carried < AgentTurnBudget.historyBytes) {
            // A call that outlived Stop must not bill another round.
            try Task.checkCancellation()
            rounds += 1
            let round = try await streamRound(
                request.continuing(with: messages, tools: toolset.tools), into: continuation)
            guard !round.calls.isEmpty else {
                continuation.yield(.finished)
                return
            }
            messages.append(AIMessage(role: .assistant, text: round.text, toolCalls: round.calls))
            budget.carry(round.text, calls: round.calls)
            let concurrent = round.calls.map { toolset.isConcurrent($0.name) }
            for batch in AgentBatchPolicy.batches(concurrent, width: Self.width) {
                try Task.checkCancellation()
                let calls = Array(round.calls[batch])
                for call in calls {
                    let tool = toolset.tools.first { $0.name == call.name }
                    continuation.yield(
                        .toolCall(
                            id: call.id, origin: tool?.origin ?? "", title: tool?.title ?? call.name))
                }
                let results = await run(calls, signal: signal, budget: &budget, into: continuation)
                messages += results.map { AIMessage(role: .tool, text: "", toolResult: $0) }
            }
        }
        throw AIProviderError.responseFailed(
            String(localized: "Stopped after \(rounds) rounds of tool calls."))
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

    /// One pass over the base route: text flows straight to the transcript, calls are collected.
    private func streamRound(
        _ request: AIRequest, into continuation: AIProviderStream.Continuation
    ) async throws -> (text: String, calls: [AIToolCall]) {
        var text = ""
        var calls: [AIToolCall] = []
        for try await event in base.stream(request) {
            try Task.checkCancellation()
            switch event {
            case .text(let delta):
                text += delta
                continuation.yield(event)
            case .toolCallRequested(let call):
                calls.append(call)
            // `.finished` is the loop's to send, once the model has stopped asking for tools.
            case .finished:
                break
            default:
                continuation.yield(event)
            }
        }
        return (text, calls)
    }
}
