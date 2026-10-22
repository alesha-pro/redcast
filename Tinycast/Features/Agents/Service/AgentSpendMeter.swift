import Foundation

/// Passes a turn through untouched and reports each cost it carries, so a capped run can stop.
struct AgentSpendMeter: AIProvider {
    let base: any AIProvider
    /// The turn's cost so far, as its route reported it; the agent loop already sums its rounds.
    let report: @Sendable (Double) -> Void

    func stream(_ request: AIRequest) -> AIProviderStream {
        AIProviderStream { continuation in
            let task = Task.detached {
                do {
                    for try await event in base.stream(request) {
                        if case .usage(let usage) = event, let cost = usage.costUSD { report(cost) }
                        continuation.yield(event)
                    }
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
}
