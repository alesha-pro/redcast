import Foundation

/// How far an agent's own tools reach: what it may read, write and run.
enum AgentAccess: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Reads its folder and its skills; writes nothing, runs nothing.
    case readOnly
    /// Writes inside its folder and runs commands there, each asking first.
    case workspaceWrite
    /// Reads and writes anywhere the account can; commands still ask first.
    case fullAccess

    var id: String { rawValue }

    var writes: Bool { self != .readOnly }
}

/// A family of built-in tools the profile switches on as one.
enum AgentToolKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case files
    case terminal
    case web
    case memory

    var id: String { rawValue }

    /// A family added later starts off, so it never switches itself on for a new agent.
    static let defaults: Set<AgentToolKind> = [.files, .terminal, .web, .memory]
}

/// Where an agent's skills come from; a project skill wins over a global one of the same name.
enum AgentSkillSource: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `<folder>/.agents/skills`
    case project
    /// `~/.agents/skills`
    case global

    var id: String { rawValue }
}

/// An agent lives in one folder: every chat with it starts there, with that folder's context.
struct AgentProfile: Codable, Hashable, Identifiable, Sendable {
    static let sfSymbol = "person.crop.circle.badge.checkmark"

    let id: UUID
    var name: String
    var iconSymbol: String?
    var instructions: String
    var model: AIModelSelection?
    /// Absolute, `~` already expanded; the folder the agent works in and reads context from.
    var directory: String
    var access: AgentAccess
    var tools: Set<AgentToolKind>
    var skillSources: Set<AgentSkillSource>
    /// Names left out of the catalog; a skill added later is in until switched off.
    var disabledSkills: Set<String>
    var readsProjectInstructions: Bool
    var readsGlobalInstructions: Bool
    /// Nil runs the agent on the chat's model with Tinycast's own tools; set, its CLI runs it.
    var runtime: AgentRuntime?
    /// The ACP mode new sessions start in, by the agent's own id for it; nil keeps its default.
    var acpMode: String?
    var createdAt: Date

    init(
        id: UUID = UUID(), name: String, iconSymbol: String? = nil, instructions: String = "",
        model: AIModelSelection? = nil, directory: String, access: AgentAccess = .workspaceWrite,
        tools: Set<AgentToolKind> = AgentToolKind.defaults,
        skillSources: Set<AgentSkillSource> = Set(AgentSkillSource.allCases),
        disabledSkills: Set<String> = [], readsProjectInstructions: Bool = true,
        readsGlobalInstructions: Bool = false, runtime: AgentRuntime? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.iconSymbol = iconSymbol
        self.instructions = instructions
        self.model = model
        self.directory = directory
        self.access = access
        self.tools = tools
        self.skillSources = skillSources
        self.disabledSkills = disabledSkills
        self.readsProjectInstructions = readsProjectInstructions
        self.readsGlobalInstructions = readsGlobalInstructions
        self.runtime = runtime
        self.createdAt = createdAt
    }

    var symbol: String { iconSymbol ?? Self.sfSymbol }
}

enum AgentProfileError: Error, LocalizedError, Equatable {
    case emptyName
    case missingDirectory
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyName: return String(localized: "Give the agent a name.")
        case .missingDirectory: return String(localized: "Choose the folder the agent works in.")
        case .storageUnavailable: return String(localized: "Tinycast couldn't save to its agents file.")
        }
    }
}
