import Foundation

/// A standing answer for one risk; MCP's three titles name them.
enum AgentConsentRule: String, CaseIterable, Codable, Sendable {
    case ask
    case always
    case never

    var title: String {
        switch self {
        case .ask: String(localized: "Ask Each Chat")
        case .always: String(localized: "Always Allow")
        case .never: String(localized: "Never Allow")
        }
    }
}

/// An agent's own answers per risk; only those that differ from the default are kept.
struct AgentConsentRules: Codable, Hashable, Sendable {
    var risks: [AgentToolRisk: AgentConsentRule] = [:]

    /// Nil once nothing differs from the default, so an untouched agent stores no rules at all.
    static func setting(_ rule: AgentConsentRule, for risk: AgentToolRisk, in rules: Self?) -> Self? {
        var updated = rules ?? Self()
        updated.risks[risk] = rule == AgentConsentPolicy.defaultRule(for: risk) ? nil : rule
        return updated.risks.isEmpty ? nil : updated
    }
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

    /// Reading and the agent's own notes never ask; the rest follow the agent, else the default.
    static func rule(for risk: AgentToolRisk, of profile: AgentProfile) -> AgentConsentRule {
        switch risk {
        case .read, .own: .always
        case .network, .personal, .change, .execute:
            profile.consent?.risks[risk] ?? defaultRule(for: risk)
        }
    }

    /// What a family's tool runs under: a tool the agent is not offered is as good as never.
    static func rule(
        for risk: AgentToolRisk, in family: AgentToolKind?, of profile: AgentProfile
    ) -> AgentConsentRule {
        guard family.map(profile.tools.contains) ?? true, risk.isOffered(to: profile.access) else {
            return .never
        }
        return rule(for: risk, of: profile)
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
