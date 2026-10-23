import Foundation

/// How much a run may do before it hands over: the agent's own, or a schedule's for its runs.
enum AgentEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case quick
    case balanced
    case thorough

    var id: String { rawValue }

    /// The least effort whose time is at least an agent's limit from the build before Effort.
    static func lasting(_ minutes: Int) -> AgentEffort {
        allCases.first { $0.budget.minutes >= minutes } ?? .thorough
    }

    var budget: AgentRunBudget {
        switch self {
        case .quick: AgentRunBudget(rounds: 8, resultBytes: 256 * 1_024, minutes: 5, subAgents: 0)
        case .balanced: AgentRunBudget(rounds: 25, resultBytes: 512 * 1_024, minutes: 15, subAgents: 2)
        case .thorough: AgentRunBudget(rounds: 60, resultBytes: 1_024 * 1_024, minutes: 45, subAgents: 4)
        }
    }

    var title: String {
        switch self {
        case .quick: String(localized: "Quick")
        case .balanced: String(localized: "Balanced")
        case .thorough: String(localized: "Thorough")
        }
    }

    /// What the level allows, in the words the editor shows under the picker.
    var summary: String {
        switch self {
        case .quick:
            String(localized: "Short tasks: up to 8 tool rounds, no sub-agents, 5 minutes in the background.")
        case .balanced:
            String(localized: "Most tasks: up to 25 tool rounds, 2 sub-agents, 15 minutes in the background.")
        case .thorough:
            String(
                localized:
                    "Long research and many steps: up to 60 tool rounds, 4 sub-agents, 45 minutes in the background.")
        }
    }
}

/// One run's limits: rounds, tool output and time each end it; sub-agents only cap `delegate`.
struct AgentRunBudget: Equatable, Sendable {
    var rounds: Int
    var resultBytes: Int
    var minutes: Int
    var subAgents: Int

    init(
        rounds: Int, resultBytes: Int = AgentTurnBudget.turnResultBytes, minutes: Int = 15, subAgents: Int = 0
    ) {
        self.rounds = rounds
        self.resultBytes = resultBytes
        self.minutes = minutes
        self.subAgents = subAgents
    }

    /// A sub-agent's: a dozen rounds of reading, inside its parent's run.
    static let subAgent = AgentRunBudget(rounds: 12, resultBytes: 256 * 1_024)
}
