import Foundation

/// Fork: how much one window chat lets its tools do unasked, over the agent's and servers' own rules.
enum ChatAccess: String, CaseIterable, Identifiable, Sendable {
    case agentSettings
    case askEveryTime
    case allowEverything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agentSettings: String(localized: "Agent's Settings")
        case .askEveryTime: String(localized: "Ask Every Time")
        case .allowEverything: String(localized: "Allow Everything")
        }
    }

    /// What the level does, for its menu row and the line under the field.
    var summary: String {
        switch self {
        case .agentSettings: String(localized: "Tools ask or run as the agent and each MCP server are set to")
        case .askEveryTime: String(localized: "Every change, command, web request and read of your data asks first")
        case .allowEverything:
            String(localized: "Tools run without asking; Never Allow still refuses, Notes and screen reads still ask")
        }
    }

    var symbol: String {
        switch self {
        case .agentSettings: "lock"
        case .askEveryTime: "hand.raised"
        case .allowEverything: "checkmark.shield"
        }
    }

    /// Only a turn someone sent from its chat takes the level; a run nobody watches keeps its rules.
    static func effective(_ level: ChatAccess, isUserTurn: Bool) -> ChatAccess {
        isUserTurn ? level : .agentSettings
    }
}
