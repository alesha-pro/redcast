import Foundation

/// Which found skills an agent is offered; nil on a profile is All, as every agent before it.
struct AgentSkillSelection: Hashable, Sendable {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        /// Every skill found but those switched off, so one added later is in.
        case all
        /// Only the skills named, so one added later stays out until picked.
        case selected

        var id: String { rawValue }
    }

    var mode: Mode
    var names: Set<String>

    init(mode: Mode = .all, names: Set<String> = []) {
        self.mode = mode
        self.names = names
    }

    /// The one rule the prompt, `load_skill` and the editor's switches all read.
    static func offers(_ name: String, in selection: Self?, disabled: Set<String>) -> Bool {
        guard let selection, selection.mode == .selected else { return !disabled.contains(name) }
        return selection.names.contains(name)
    }
}

/// Read leniently: a mode a newer build wrote reads as All, and missing names as none.
extension AgentSkillSelection: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode, names
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try? values.decodeIfPresent(String.self, forKey: .mode)
        self.mode = mode.flatMap(Mode.init(rawValue:)) ?? .all
        names = Set((try? values.decodeIfPresent([String].self, forKey: .names)) ?? [])
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode.rawValue, forKey: .mode)
        try values.encode(names.sorted(), forKey: .names)
    }
}
