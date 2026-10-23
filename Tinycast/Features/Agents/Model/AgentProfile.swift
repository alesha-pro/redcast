import Foundation

/// How far an agent's own tools reach: what it may read, write and run.
enum AgentAccess: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Reads its folder and its skills; writes nothing, runs nothing.
    case readOnly
    /// Writes inside its folder and runs commands there; its consent rules say which ask first.
    case workspaceWrite
    /// Reads and writes anywhere the account can, and runs commands; the same rules apply.
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
    /// The user's Tinycast Notes: search, read and add to them.
    case notes
    /// The text of the window behind Tinycast, while Screen Awareness is on.
    case screen
    /// `delegate`: a read-only sub-agent on the same model.
    case delegate

    var id: String { rawValue }

    /// A family added later starts off, so it never switches itself on for a new agent.
    static let defaults: Set<AgentToolKind> = [.files, .terminal, .web, .memory]
    /// A build from before these fails on them inside `tools`, so they are written under their own key.
    static let unknownToOlderBuilds: Set<AgentToolKind> = [.screen, .delegate]
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
struct AgentProfile: Hashable, Identifiable, Sendable {
    static let sfSymbol = "person.crop.circle.badge.checkmark"

    let id: UUID
    var name: String
    var iconSymbol: String?
    /// A `RaycastHue` name; nil, or one a newer build added, takes the colour derived from `id`.
    var color: String?
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
    /// The model new sessions start on, by the agent's own id for it; nil keeps its default.
    var acpModel: String?
    /// Its reasoning level, applied after the model, whose levels it must be among.
    var acpReasoning: String?
    /// The agent's other selects, by its own option ids; nil while none was picked.
    var acpOptions: [String: String]?
    /// Optional, so every `agents.json` written before it still decodes; nil keeps the defaults.
    var consent: AgentConsentRules?
    /// How a run nobody started from a chat behaves; nil is `AgentBackgroundPolicy()`.
    var background: AgentBackgroundPolicy?
    /// How much a run may do; nil follows `effortLevel`, and the previous build ignores the key.
    var effort: AgentEffort?
    var createdAt: Date

    init(
        id: UUID = UUID(), name: String, iconSymbol: String? = nil, color: String? = nil,
        instructions: String = "",
        model: AIModelSelection? = nil, directory: String, access: AgentAccess = .workspaceWrite,
        tools: Set<AgentToolKind> = AgentToolKind.defaults,
        skillSources: Set<AgentSkillSource> = Set(AgentSkillSource.allCases),
        disabledSkills: Set<String> = [], readsProjectInstructions: Bool = true,
        readsGlobalInstructions: Bool = false, runtime: AgentRuntime? = nil,
        consent: AgentConsentRules? = nil, background: AgentBackgroundPolicy? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.iconSymbol = iconSymbol
        self.color = color
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
        self.consent = consent
        self.background = background
        self.createdAt = createdAt
    }

    var symbol: String { iconSymbol ?? Self.sfSymbol }

    var backgroundPolicy: AgentBackgroundPolicy { background ?? AgentBackgroundPolicy() }

    /// Nil reads the time limit an agent kept before Effort: a 30-minute agent was not a Balanced one.
    var effortLevel: AgentEffort { effort ?? AgentEffort.lasting(backgroundPolicy.minutes) }

    /// Its launcher row's id; apart from the `@handle` rows' `agent:` and `agent-pick:` ids.
    static let entryIDPrefix = "agent-profile:"

    var entryID: String { Self.entryIDPrefix + id.uuidString.lowercased() }

    static func id(fromEntryID entryID: String) -> UUID? {
        guard entryID.hasPrefix(entryIDPrefix) else { return nil }
        return UUID(uuidString: String(entryID.dropFirst(entryIDPrefix.count)))
    }
}

/// Written by hand only so a newer family never lands where the previous build reads `tools`.
extension AgentProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, iconSymbol, color, instructions, model, directory, access, tools, addedTools
        case skillSources, disabledSkills, readsProjectInstructions, readsGlobalInstructions, runtime
        case acpMode, acpModel, acpReasoning, acpOptions, consent, background, effort, createdAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        iconSymbol = try values.decodeIfPresent(String.self, forKey: .iconSymbol)
        color = try values.decodeIfPresent(String.self, forKey: .color)
        instructions = try values.decode(String.self, forKey: .instructions)
        model = try values.decodeIfPresent(AIModelSelection.self, forKey: .model)
        directory = try values.decode(String.self, forKey: .directory)
        access = try values.decode(AgentAccess.self, forKey: .access)
        let named =
            try values.decode([String].self, forKey: .tools)
            + (values.decodeIfPresent([String].self, forKey: .addedTools) ?? [])
        // A family from a newer build is left out rather than costing every agent.
        tools = Set(named.compactMap(AgentToolKind.init(rawValue:)))
        skillSources = try values.decode(Set<AgentSkillSource>.self, forKey: .skillSources)
        disabledSkills = try values.decode(Set<String>.self, forKey: .disabledSkills)
        readsProjectInstructions = try values.decode(Bool.self, forKey: .readsProjectInstructions)
        readsGlobalInstructions = try values.decode(Bool.self, forKey: .readsGlobalInstructions)
        runtime = try values.decodeIfPresent(AgentRuntime.self, forKey: .runtime)
        acpMode = try values.decodeIfPresent(String.self, forKey: .acpMode)
        acpModel = try values.decodeIfPresent(String.self, forKey: .acpModel)
        acpReasoning = try values.decodeIfPresent(String.self, forKey: .acpReasoning)
        acpOptions = try values.decodeIfPresent([String: String].self, forKey: .acpOptions)
        consent = try values.decodeIfPresent(AgentConsentRules.self, forKey: .consent)
        background = try values.decodeIfPresent(AgentBackgroundPolicy.self, forKey: .background)
        effort = try values.decodeIfPresent(AgentEffort.self, forKey: .effort)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(iconSymbol, forKey: .iconSymbol)
        try values.encodeIfPresent(color, forKey: .color)
        try values.encode(instructions, forKey: .instructions)
        try values.encodeIfPresent(model, forKey: .model)
        try values.encode(directory, forKey: .directory)
        try values.encode(access, forKey: .access)
        try values.encode(tools.subtracting(AgentToolKind.unknownToOlderBuilds), forKey: .tools)
        let added = tools.intersection(AgentToolKind.unknownToOlderBuilds)
        if !added.isEmpty { try values.encode(added, forKey: .addedTools) }
        try values.encode(skillSources, forKey: .skillSources)
        try values.encode(disabledSkills, forKey: .disabledSkills)
        try values.encode(readsProjectInstructions, forKey: .readsProjectInstructions)
        try values.encode(readsGlobalInstructions, forKey: .readsGlobalInstructions)
        try values.encodeIfPresent(runtime, forKey: .runtime)
        try values.encodeIfPresent(acpMode, forKey: .acpMode)
        try values.encodeIfPresent(acpModel, forKey: .acpModel)
        try values.encodeIfPresent(acpReasoning, forKey: .acpReasoning)
        try values.encodeIfPresent(acpOptions, forKey: .acpOptions)
        try values.encodeIfPresent(consent, forKey: .consent)
        try values.encodeIfPresent(background, forKey: .background)
        try values.encodeIfPresent(effort, forKey: .effort)
        try values.encode(createdAt, forKey: .createdAt)
    }
}

/// What an unattended run does with a request that would ask: a change, a command, a permission.
enum AgentBackgroundConsent: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The dialog, only while someone is at the Mac and with Return on Don't Allow; else declined.
    case ask
    /// Refused at once; the model is told so and reports what it would have done.
    case decline

    var id: String { rawValue }
}

struct AgentBackgroundPolicy: Codable, Hashable, Sendable {
    var consent: AgentBackgroundConsent = .ask
    /// A Notification Center banner when a run ends; opt-in, since macOS asks for it once.
    var notifies = false
    /// An agent on its own CLI stops a run after this long; Tinycast's loop takes its time from Effort.
    var minutes = 15

    static let minuteRange = 5...60

    /// The limit a run is held to, inside the range even when a hand-edited file says otherwise.
    var limitMinutes: Int { min(max(minutes, Self.minuteRange.lowerBound), Self.minuteRange.upperBound) }
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
