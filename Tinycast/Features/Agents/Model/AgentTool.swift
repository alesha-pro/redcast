import Foundation

/// What a call reaches; it decides which agents are offered the tool and who is asked first.
enum AgentToolRisk: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case read  // the folder, skills, the agent's notes
    case own  // writes only the agent's own notes or plan
    case network  // text leaves the Mac: a URL, a query
    case personal  // the user's data beyond the folder: notes, the screen
    case change  // the user's files or notes, changed
    case execute  // a program, run

    /// What a sub-agent may reach: nothing it changes, writes down or runs.
    static let reads: Set<AgentToolRisk> = [.read, .network, .personal]

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
    /// A schedule's or the launcher's run: nobody sent it, though a dialog may still reach them.
    var isBackground = false

    /// The user sent this turn from its chat; never a background run or a sub-agent.
    var isUserTurn: Bool {
        guard case .chat = mode else { return false }
        return !isBackground
    }
}

enum AgentRunMode: Hashable, Sendable {
    /// Someone is in this chat to ask.
    case chat(UUID)
    /// Nobody to ask, so a rule of ask refuses.
    case unattended(UUID)

    var chatID: UUID {
        switch self {
        case .chat(let id), .unattended(let id): id
        }
    }
}

/// What a change or command looks like to the person asked to allow it.
struct AgentConsentRequest: Sendable {
    let summary: String
    let detail: String
}

/// What a call may add to the transcript besides its own row, or to what the turn cost.
enum AgentToolSignal: Sendable {
    case searching(String)
    case searched(String)
    case reasoning(String)
    /// A call's own model spend, as a sub-agent's, billed into the turn rather than shown.
    case spent(Double)

    var event: AIStreamEvent? {
        switch self {
        case .searching(let query): .searching(query)
        case .searched(let query): .searched(query)
        case .reasoning(let text): .reasoning(text)
        case .spent: nil
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
    /// What this call's row says instead of the tool's title, as a sub-task's name.
    func title(for call: AIToolCall) -> String?
}

extension AgentToolProvider {
    func title(for call: AIToolCall) -> String? { nil }
}
