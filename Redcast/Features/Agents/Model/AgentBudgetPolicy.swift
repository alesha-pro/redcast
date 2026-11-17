import Foundation

/// When a run is told to wrap up, when it must hand over, and the words the model reads for each.
enum AgentBudgetPolicy {
    /// Past this share of any limit the model is asked to finish what it has.
    static let wrapUpShare = 0.8
    /// A plan nobody updated for this many rounds is read back to the model, so it stays in view.
    static let reciteEvery = 6

    enum Step: Equatable, Sendable {
        case go
        case wrapUp(String)
        case handOver(String)
    }

    /// What a run has used so far.
    struct Usage: Equatable, Sendable {
        var rounds: Int
        var resultBytes: Int
        var carried: Int
        var elapsed: Duration
    }

    /// Decided after each round of calls; a wrap-up is said once, a hand-over ends the run.
    static func step(
        after usage: Usage, of budget: AgentRunBudget, timeLimit: Duration?, warned: Bool
    ) -> Step {
        if usage.rounds >= budget.rounds { return .handOver("\(usage.rounds) of \(budget.rounds) rounds used") }
        if usage.resultBytes >= budget.resultBytes { return .handOver("the run's tool output allowance is used") }
        if usage.carried >= AgentTurnBudget.historyBytes { return .handOver("the conversation is at its size limit") }
        let limit = timeLimit.map(minutes)
        if let timeLimit, usage.elapsed >= timeLimit, let limit {
            return .handOver("\(limit) of \(limit) minutes used")
        }
        guard !warned else { return .go }
        if budget.rounds > 2, Double(usage.rounds) >= (Double(budget.rounds) * wrapUpShare).rounded(.up) {
            return .wrapUp("\(usage.rounds) of \(budget.rounds) rounds used")
        }
        if Double(usage.resultBytes) >= Double(budget.resultBytes) * wrapUpShare {
            return .wrapUp("most of the run's tool output allowance is used")
        }
        if let timeLimit, let limit, usage.elapsed >= timeLimit * wrapUpShare {
            return .wrapUp("\(minutes(usage.elapsed)) of \(limit) minutes used")
        }
        return .go
    }

    static func wrapUp(_ used: String, plan: [AgentPlan.Item]?) -> String {
        "[Run budget: \(used). Start wrapping up: finish the step in hand, check the key facts you rely "
            + "on, then give your answer. Do not start new lines of work.]" + recital(plan, leading: "\n")
    }

    static func handOver(_ spent: String, plan: [AgentPlan.Item]?) -> String {
        "[Run budget spent: \(spent). Tools are off now: do not call any. Write your final answer now: "
            + "the result, what is done, what is not and why, and what to do next. Report only what the "
            + "results above establish.]" + recital(plan, leading: "\n")
    }

    /// Why a run hands over when even its shed conversation no longer fits the model's window.
    static let windowFull = "the conversation no longer fits the model's window"

    /// The answer to a call the hand-over round made anyway: nothing runs once the budget is spent.
    static let callsOff =
        "Not run: this run's budget is spent and tools are off. Write your final answer now from the "
        + "results above."

    /// The plan in one line, so the model sees where it is without the checklist's full fold.
    static func recital(_ plan: [AgentPlan.Item]?, leading: String = "") -> String {
        guard let plan, !plan.isEmpty else { return "" }
        let steps = plan.map { item in
            switch item.status {
            case .completed: "✓ " + item.step
            case .inProgress: "→ " + item.step
            case .pending: "· " + item.step
            }
        }
        return leading + "[Plan: " + steps.joined(separator: "; ") + "]"
    }

    private static func minutes(_ duration: Duration) -> Int {
        Int(duration.components.seconds / 60)
    }
}
