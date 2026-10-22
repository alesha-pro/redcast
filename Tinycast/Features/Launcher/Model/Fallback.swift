import Foundation

/// A launcher fallback: the typed query is its input, so it is offered whatever the query says.
enum Fallback: Hashable, Sendable {
    /// The shipped destinations, in the order a fresh install offers them.
    enum Builtin: String, CaseIterable, Sendable {
        case quickAI
        case searchFiles
        case runShellCommand
        case define
        case agentSessions

        /// Where its name and glyph come from, so a fallback row reads like the command it runs.
        var command: CommandID {
            switch self {
            case .quickAI: return .quickAI
            case .searchFiles: return .searchFiles
            case .runShellCommand: return .runShellCommand
            case .define: return .define
            case .agentSessions: return .searchAgentSessions
            }
        }
    }

    case builtin(Builtin)
    case quicklink(UUID)
    /// `@handle task` in root search; never in `available`, so Settings never lists it.
    case agent(UUID)
    case agentPick(UUID)

    static let agentPrefix = "agent:"
    static let agentPickPrefix = "agent-pick:"

    /// The row's `AppEntry` id, so a stored order outlives a rename and survives a reinstall.
    var id: String {
        switch self {
        case .builtin(let builtin): return builtin.command.rawValue
        case .quicklink(let id): return Quicklink.entryIDPrefix + id.uuidString.lowercased()
        case .agent(let id): return Self.agentPrefix + id.uuidString.lowercased()
        case .agentPick(let id): return Self.agentPickPrefix + id.uuidString.lowercased()
        }
    }

    init?(id: String) {
        if id.hasPrefix(Self.agentPrefix),
            let agent = UUID(uuidString: String(id.dropFirst(Self.agentPrefix.count)))
        {
            self = .agent(agent)
        } else if id.hasPrefix(Self.agentPickPrefix),
            let agent = UUID(uuidString: String(id.dropFirst(Self.agentPickPrefix.count)))
        {
            self = .agentPick(agent)
        } else if let command = CommandID(rawValue: id),
            let builtin = Builtin.allCases.first(where: { $0.command == command })
        {
            self = .builtin(builtin)
        } else if let quicklink = Quicklink.id(fromEntryID: id) {
            self = .quicklink(quicklink)
        } else {
            return nil
        }
    }

    var openVerb: String {
        switch self {
        case .builtin(.quickAI): return String(localized: "Ask Quick AI")
        case .builtin(.searchFiles): return String(localized: "Search Files")
        case .builtin(.runShellCommand): return String(localized: "Run Shell Command")
        case .builtin(.define): return String(localized: "Define Word")
        case .builtin(.agentSessions): return String(localized: "Search Agent Sessions")
        case .quicklink: return String(localized: "Open Quicklink")
        case .agent: return String(localized: "Run in Background")
        case .agentPick: return String(localized: "Choose Agent")
        }
    }

    /// Stored order first, then anything it has never seen — a quicklink added today lands last.
    static func ordered(_ available: [Fallback], by storedIDs: [String]) -> [Fallback] {
        var remaining = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = storedIDs.compactMap { remaining.removeValue(forKey: $0) }
        return known + available.filter { remaining[$0.id] != nil }
    }

    /// The section header. A long query is elided in the middle, so “with…” always survives.
    static func sectionTitle(query: String, limit: Int = 72) -> String {
        guard query.count > limit else { return String(localized: "Use “\(query)” with…") }
        let elided = "\(query.prefix(limit / 2))…\(query.suffix(limit - limit / 2 - 1))"
        return String(localized: "Use “\(elided)” with…")
    }
}
