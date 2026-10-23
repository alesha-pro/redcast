import Foundation

/// One select a session offers: a Session Config Option, or the older models or modes as one.
struct ACPConfigOption: Equatable, Identifiable, Sendable {
    /// How a choice reaches the agent; the older shapes each have a method of their own.
    enum Setter: Equatable, Sendable {
        case configOption
        case legacyModel
        case legacyMode
    }

    /// ACP's categories are hints; one this build does not know is any other select.
    enum Category: Equatable, Sendable {
        case mode
        case model
        case thoughtLevel
        case other

        init(_ raw: String?) {
            switch raw {
            case "mode": self = .mode
            case "model": self = .model
            case "thought_level": self = .thoughtLevel
            default: self = .other
            }
        }
    }

    struct Choice: Equatable, Identifiable, Sendable {
        let value: String
        let name: String
        let description: String?

        var id: String { value }
    }

    /// A flat list is one group without a name.
    struct Group: Equatable, Identifiable, Sendable {
        let id: String
        let name: String?
        let choices: [Choice]
    }

    let id: String
    let name: String
    let description: String?
    let category: Category
    let setter: Setter
    var current: String
    let groups: [Group]

    static let maxOptions = 32
    static let maxChoices = 500
    static let maxNameLength = 120
    static let maxDescriptionLength = 200

    var choices: [Choice] { groups.flatMap(\.choices) }

    func offers(_ value: String) -> Bool {
        groups.contains { $0.choices.contains { $0.value == value } }
    }

    /// A current value the list lacks, as a model the agent no longer lists, shows as itself.
    var currentTitle: String {
        choices.first { $0.value == current }?.name ?? current
    }

    /// The request that moves a live session to `value`, by the method this option came with.
    func request(setting value: String, session: String) -> (method: String, params: [String: Any]) {
        switch setter {
        case .configOption:
            ("session/set_config_option", ["sessionId": session, "configId": id, "value": value])
        case .legacyModel:
            ("session/set_model", ["sessionId": session, "modelId": value])
        case .legacyMode:
            ("session/set_mode", ["sessionId": session, "modeId": value])
        }
    }

    /// `configOptions` as sent; nil when the key is absent, so a reply without it changes nothing.
    static func list(_ value: JSONValue?) -> [ACPConfigOption]? {
        guard let items = value?.arrayValue else { return nil }
        return Array(items.compactMap(ACPConfigOption.init(config:)).prefix(maxOptions))
    }

    /// Selects only: a boolean goes only to a client that declared it, which Tinycast doesn't.
    init?(config value: JSONValue) {
        guard let object = value.objectValue, object["type"]?.stringValue == "select",
            let id = object["id"]?.stringValue, let current = object["currentValue"]?.stringValue
        else { return nil }
        var budget = Self.maxChoices
        var groups: [Group] = []
        for item in object["options"]?.arrayValue ?? [] {
            guard let entry = item.objectValue else { continue }
            if let nested = entry["options"]?.arrayValue {
                let choices = Self.choices(nested.compactMap(\.objectValue), budget: &budget)
                guard !choices.isEmpty else { continue }
                groups.append(
                    Group(
                        id: entry["group"]?.stringValue ?? "\(groups.count)",
                        name: Self.clipped(entry["name"]?.stringValue, to: Self.maxNameLength),
                        choices: choices))
            } else if let choice = Self.choices([entry], budget: &budget).first {
                if let last = groups.last, last.name == nil {
                    groups[groups.count - 1] = Group(id: last.id, name: nil, choices: last.choices + [choice])
                } else {
                    groups.append(Group(id: "\(groups.count)", name: nil, choices: [choice]))
                }
            }
        }
        guard !groups.isEmpty else { return nil }
        self.init(
            id: id, name: Self.clipped(object["name"]?.stringValue, to: Self.maxNameLength) ?? id,
            description: Self.clipped(object["description"]?.stringValue, to: Self.maxDescriptionLength),
            category: Category(object["category"]?.stringValue), setter: .configOption, current: current,
            groups: groups)
    }

    /// The older `models`, which `session/set_model` switches.
    init?(legacyModels value: JSONValue?) {
        guard let models = value?.objectValue else { return nil }
        var budget = Self.maxChoices
        let entries = (models["availableModels"]?.arrayValue ?? []).compactMap { item -> [String: JSONValue]? in
            guard var model = item.objectValue else { return nil }
            model["value"] = model["modelId"]
            return model
        }
        let choices = Self.choices(entries, budget: &budget)
        guard !choices.isEmpty else { return nil }
        self.init(
            id: "session/set_model", name: "Model", description: nil, category: .model, setter: .legacyModel,
            current: models["currentModelId"]?.stringValue ?? "",
            groups: [Group(id: "", name: nil, choices: choices)])
    }

    /// The older `modes`, which `session/set_mode` switches.
    init?(legacyModes value: JSONValue?) {
        guard let modes = value?.objectValue else { return nil }
        var budget = Self.maxChoices
        let entries = (modes["availableModes"]?.arrayValue ?? []).compactMap { item -> [String: JSONValue]? in
            guard var mode = item.objectValue else { return nil }
            mode["value"] = mode["id"]
            return mode
        }
        let choices = Self.choices(entries, budget: &budget)
        guard !choices.isEmpty else { return nil }
        self.init(
            id: "session/set_mode", name: "Mode", description: nil, category: .mode, setter: .legacyMode,
            current: modes["currentModeId"]?.stringValue ?? "",
            groups: [Group(id: "", name: nil, choices: choices)])
    }

    init(
        id: String, name: String, description: String?, category: Category, setter: Setter, current: String,
        groups: [Group]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.setter = setter
        self.current = current
        self.groups = groups
    }

    private static func choices(_ entries: [[String: JSONValue]], budget: inout Int) -> [Choice] {
        var choices: [Choice] = []
        for entry in entries where budget > 0 {
            guard let value = entry["value"]?.stringValue else { continue }
            budget -= 1
            choices.append(
                Choice(
                    value: value, name: clipped(entry["name"]?.stringValue, to: maxNameLength) ?? value,
                    description: clipped(entry["description"]?.stringValue, to: maxDescriptionLength)))
        }
        return choices
    }

    /// One line, cut to fit a menu row; an empty string is no text at all.
    private static func clipped(_ text: String?, to limit: Int) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count <= limit ? line : String(line.prefix(limit - 1)) + "…"
    }
}

/// Where a remembered choice goes: one of the composer's own pickers, or another select by its id.
enum ACPChoiceSlot: Hashable, Sendable {
    case model
    case reasoning
    case mode
    case option(String)
}

/// What a session lets the user choose, in the agent's order.
struct ACPSessionOptions: Equatable, Sendable {
    private(set) var options: [ACPConfigOption]

    /// What a remembered value comes to against what a session offers now.
    enum Step: Equatable, Sendable {
        case keep
        case forget
        case send(ACPConfigOption)
    }

    init(options: [ACPConfigOption]) {
        self.options = options
    }

    /// From `session/new` or `session/load`; an older shape only where no option has its category.
    init?(result: JSONValue) {
        let object = result.objectValue ?? [:]
        var options = ACPConfigOption.list(object["configOptions"]) ?? []
        if !options.contains(where: { $0.category == .model }),
            let models = ACPConfigOption(legacyModels: object["models"])
        {
            options.append(models)
        }
        if !options.contains(where: { $0.category == .mode }),
            let modes = ACPConfigOption(legacyModes: object["modes"])
        {
            options.append(modes)
        }
        guard !options.isEmpty else { return nil }
        self.init(options: options)
    }

    var model: ACPConfigOption? { options.first { $0.category == .model } }
    var reasoning: ACPConfigOption? { options.first { $0.category == .thoughtLevel } }
    var mode: ACPConfigOption? { options.first { $0.category == .mode } }

    /// Every select but the three the composer shows as pickers of their own.
    var others: [ACPConfigOption] {
        options.filter { slot(of: $0) == .option($0.id) }
    }

    func slot(of option: ACPConfigOption) -> ACPChoiceSlot {
        if option.id == model?.id { return .model }
        if option.id == reasoning?.id { return .reasoning }
        if option.id == mode?.id { return .mode }
        return .option(option.id)
    }

    func option(for slot: ACPChoiceSlot) -> ACPConfigOption? {
        switch slot {
        case .model: model
        case .reasoning: reasoning
        case .mode: mode
        case .option(let id): others.first { $0.id == id }
        }
    }

    /// A value already in effect is kept even when unlisted; an option nobody offers keeps it too.
    func step(for slot: ACPChoiceSlot, wanting value: String) -> Step {
        guard let option = option(for: slot), option.current != value else { return .keep }
        return option.offers(value) ? .send(option) : .forget
    }

    /// The agent's whole list after a change; an empty one, as Hermes answers, changes nothing.
    mutating func replace(with config: [ACPConfigOption]) {
        guard !config.isEmpty else { return }
        let older = options.filter { option in
            option.setter != .configOption && !config.contains { $0.category == option.category }
        }
        options = config + older
    }

    /// A set's answer: the list it carries, or else only the value that was picked.
    mutating func settle(_ value: String, in optionID: String, answer: JSONValue) {
        let listed = ACPConfigOption.list(answer.objectValue?["configOptions"]) ?? []
        if listed.isEmpty {
            select(value, in: optionID)
        } else {
            replace(with: listed)
        }
    }

    mutating func select(_ value: String, in optionID: String) {
        guard let index = options.firstIndex(where: { $0.id == optionID }) else { return }
        options[index].current = value
    }

    /// `current_mode_update` moves whichever shape the mode came in.
    mutating func moveMode(to value: String) {
        guard let mode, mode.offers(value) else { return }
        select(value, in: mode.id)
    }

    /// A chat with no session yet: the agent's last list, on the values it remembers.
    func applying(_ agent: AgentProfile) -> ACPSessionOptions {
        var applied = self
        for (slot, value) in agent.acpWishes {
            guard let option = applied.option(for: slot), option.offers(value) else { continue }
            applied.select(value, in: option.id)
        }
        return applied
    }
}

extension AgentProfile {
    func acpChoice(for slot: ACPChoiceSlot) -> String? {
        switch slot {
        case .model: acpModel
        case .reasoning: acpReasoning
        case .mode: acpMode
        case .option(let id): acpOptions?[id]
        }
    }

    mutating func setACPChoice(_ value: String?, for slot: ACPChoiceSlot) {
        switch slot {
        case .model: acpModel = value
        case .reasoning: acpReasoning = value
        case .mode: acpMode = value
        case .option(let id):
            var options = acpOptions ?? [:]
            options[id] = value
            acpOptions = options.isEmpty ? nil : options
        }
    }

    /// Model first: the levels and options a session offers follow the model it is on.
    var acpWishes: [(slot: ACPChoiceSlot, value: String)] {
        var wishes: [(slot: ACPChoiceSlot, value: String)] = []
        if let acpModel { wishes.append((.model, acpModel)) }
        if let acpReasoning { wishes.append((.reasoning, acpReasoning)) }
        if let acpMode { wishes.append((.mode, acpMode)) }
        for (id, value) in (acpOptions ?? [:]).sorted(by: { $0.key < $1.key }) {
            wishes.append((.option(id), value))
        }
        return wishes
    }

    /// A different program's names mean nothing to the next one.
    mutating func forgetACPChoices() {
        acpModel = nil
        acpReasoning = nil
        acpMode = nil
        acpOptions = nil
    }
}
