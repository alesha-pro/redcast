import Foundation

/// A standing answer for one risk; MCP's three titles name them.
enum AgentConsentRule: String, CaseIterable, Sendable {
    case ask
    case always
    case never
}

/// What "Allow for This Chat" covers: one family's one risk, so a grant never spreads.
struct AgentGrant: Hashable, Sendable {
    let family: AgentToolKind?
    let risk: AgentToolRisk
}

/// Whether one call may go ahead: its rule, and whether anyone is there to ask.
enum AgentConsentPolicy {
    enum Verdict: Equatable, Sendable {
        case allow
        case ask
        case refuse
    }

    /// Today's behaviour: only changes and commands stop to ask.
    static func defaultRule(for risk: AgentToolRisk) -> AgentConsentRule {
        switch risk {
        case .read, .own, .network, .personal: .always
        case .change, .execute: .ask
        }
    }

    static func rule(for spec: AgentToolSpec) -> AgentConsentRule {
        defaultRule(for: spec.risk)
    }

    static func decide(_ rule: AgentConsentRule, mode: AgentRunMode) -> Verdict {
        switch (rule, mode) {
        case (.never, _): .refuse
        case (.always, _): .allow
        case (.ask, .chat): .ask
        case (.ask, .unattended): .refuse
        }
    }
}
