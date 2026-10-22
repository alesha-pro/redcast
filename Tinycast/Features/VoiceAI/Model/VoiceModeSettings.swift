import Foundation

/// Everything about dictation modes, kept as one JSON value; a missing field reads as its default.
struct VoiceModeSettings: Codable, Equatable, Sendable {
    /// What an app's entry holds to type the plain transcript whatever the default says.
    static let plain = "plain"

    var custom: [VoiceMode] = []
    /// A built-in's instructions as the reader rewrote them, by the built-in's id.
    var overrides: [String: String] = [:]
    /// Modes Tab skips; an app's entry or the default may still name one.
    var hidden: Set<UUID> = []
    var defaultMode: UUID?
    /// Bundle id to a mode's id, or `plain`; an app without an entry follows the default.
    var apps: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case custom, overrides, hidden, defaultMode, apps
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        custom = try container.decodeIfPresent([VoiceMode].self, forKey: .custom) ?? []
        overrides = try container.decodeIfPresent([String: String].self, forKey: .overrides) ?? [:]
        hidden = try container.decodeIfPresent(Set<UUID>.self, forKey: .hidden) ?? []
        defaultMode = try container.decodeIfPresent(UUID.self, forKey: .defaultMode)
        apps = try container.decodeIfPresent([String: String].self, forKey: .apps) ?? [:]
    }

    /// The built-ins, with any rewritten instructions, then the reader's own in creation order.
    var all: [VoiceMode] {
        VoiceModeCatalog.builtIns.map { mode in
            var mode = mode
            if let override = overrides[mode.id.uuidString] { mode.instructions = override }
            return mode
        } + custom
    }

    func mode(id: UUID?) -> VoiceMode? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// The app's own entry, else the default; a mode since deleted is the plain transcript.
    func mode(for bundleID: String?) -> VoiceMode? {
        guard let bundleID, let entry = apps[bundleID] else { return mode(id: defaultMode) }
        return mode(id: UUID(uuidString: entry))
    }

    /// Tab's order: the plain transcript, then every mode not hidden; an unlisted current starts it.
    func next(after current: UUID?, backward: Bool = false) -> VoiceMode? {
        let cycle: [VoiceMode?] = [nil] + all.filter { !hidden.contains($0.id) }
        let index = cycle.firstIndex { $0?.id == current } ?? 0
        let step = backward ? cycle.count - 1 : 1
        return cycle[(index + step) % cycle.count]
    }

    /// An app's choice; one equal to the default is no entry at all, so it follows the default.
    mutating func assign(_ id: UUID?, to bundleID: String?) {
        guard let bundleID else {
            defaultMode = id
            return
        }
        apps[bundleID] = id == defaultMode ? nil : id?.uuidString ?? Self.plain
    }

    /// A new or edited mode; a built-in keeps its name and stores only rewritten instructions.
    mutating func save(_ mode: VoiceMode) {
        if let builtIn = VoiceModeCatalog.builtIn(mode.id) {
            let rewritten = mode.instructions != builtIn.instructions
            overrides[mode.id.uuidString] = rewritten ? mode.instructions : nil
        } else if let index = custom.firstIndex(where: { $0.id == mode.id }) {
            custom[index] = mode
        } else {
            custom.append(mode)
        }
    }

    /// A deleted mode leaves nothing naming it; a built-in is only ever reset, never removed.
    mutating func remove(_ id: UUID) {
        guard !VoiceModeCatalog.isBuiltIn(id) else {
            overrides[id.uuidString] = nil
            return
        }
        custom.removeAll { $0.id == id }
        hidden.remove(id)
        if defaultMode == id { defaultMode = nil }
        apps = apps.filter { $0.value != id.uuidString }
    }

    mutating func setHidden(_ isHidden: Bool, _ id: UUID) {
        if isHidden { hidden.insert(id) } else { hidden.remove(id) }
    }
}
