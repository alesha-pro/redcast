import Foundation

/// What a call reaches; it decides which agents are offered the tool and who is asked first.
enum AgentToolRisk: String, CaseIterable, Sendable {
    case read  // the folder, skills, the agent's notes
    case own  // writes only the agent's own notes or plan
    case network  // text leaves the Mac: a URL, a query
    case personal  // the user's data beyond the folder: notes, the screen
    case change  // the user's files or notes, changed
    case execute  // a program, run

    /// A read-only agent changes nothing and runs nothing, whichever provider offers it.
    func isOffered(to access: AgentAccess) -> Bool {
        switch self {
        case .change, .execute: access.writes
        case .read, .own, .network, .personal: true
        }
    }
}

/// One tool as a turn offers it, and what it reaches.
struct AgentToolSpec: Sendable {
    let tool: AITool
    /// Nil when no profile switch governs it, as `load_skill` or a plan.
    let family: AgentToolKind?
    let risk: AgentToolRisk
    /// No effect and no dialog of its own, so it may run beside its neighbours in a round.
    let concurrent: Bool

    var grant: AgentGrant { AgentGrant(family: family, risk: risk) }
}

/// What every provider reads about the turn it serves.
struct AgentTurn: Sendable {
    let profile: AgentProfile
    let skills: [AgentSkill]
    let memoryURL: URL
    let mode: AgentRunMode
}

enum AgentRunMode: Hashable, Sendable {
    /// Someone is in this chat to ask.
    case chat(UUID)
    /// Nobody to ask, so a rule of ask refuses.
    case unattended(UUID)
}

/// What a change or command looks like to the person asked to allow it.
struct AgentConsentRequest: Sendable {
    let summary: String
    let detail: String
}

/// What a call may add to the transcript besides its own row.
enum AgentToolSignal: Sendable {
    case searching(String)
    case searched(String)
    case reasoning(String)

    var event: AIStreamEvent {
        switch self {
        case .searching(let query): .searching(query)
        case .searched(let query): .searched(query)
        case .reasoning(let text): .reasoning(text)
        }
    }
}

/// One call's view of its turn: the facts, the consent its rule allows, and the transcript.
struct AgentToolContext: Sendable {
    let turn: AgentTurn
    /// Called before any effect beyond reading; false means do nothing and say so.
    let consent: @Sendable (AgentConsentRequest) async -> Bool
    let signal: @Sendable (AgentToolSignal) -> Void
}

/// A family of tools: what it can offer a turn, and one call run off-main.
protocol AgentToolProvider: Sendable {
    /// Everything it can offer now; the toolset applies the profile, the access and the rules.
    func specs(for turn: AgentTurn) -> [AgentToolSpec]
    func run(_ call: AIToolCall, in context: AgentToolContext) async -> AIToolResult
}
