import Foundation

/// Fork: a sidebar folder; its chats may share standing instructions and start on one agent.
struct ChatFolder: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// A `RaycastHue` name; one this build doesn't know reads as the id's derived hue.
    var color: String
    var symbol: String
    /// Sent after the app's prompt and before the chat's own, in every chat filed here.
    var instructions: String?
    /// The agent a chat started in this folder begins on.
    var agentID: UUID?
    var isCollapsed = false
    /// Fields a newer build wrote, written back untouched.
    var unknown: [String: JSONValue] = [:]

    init(
        id: UUID = UUID(), name: String, color: RaycastHue, symbol: String,
        instructions: String? = nil, agentID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color.rawValue
        self.symbol = symbol
        self.instructions = instructions
        self.agentID = agentID
    }

    var hue: RaycastHue { RaycastHue.agent(named: color, id: id) }

    /// Trimmed and capped, so a pasted essay cannot become a sidebar row.
    static func cleanName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(nameLimit))
    }

    static let nameLimit = 60

    /// The icon set a folder picks from; the first is a new folder's.
    static let symbols = [
        "folder.fill", "star.fill", "briefcase.fill", "book.fill", "hammer.fill",
        "lightbulb.fill", "graduationcap.fill", "heart.fill", "leaf.fill", "globe",
        "terminal.fill", "paintbrush.fill", "chart.bar.fill", "cart.fill", "airplane",
        "gamecontroller.fill"
    ]

    static let hues = RaycastHue.agentChoices

    /// A new folder takes the next hue in the palette, so three folders are three colours.
    static func nextHue(after folders: [ChatFolder]) -> RaycastHue {
        hues[folders.count % hues.count]
    }
}

extension ChatFolder {
    private enum Key {
        static let id = "id", name = "name", color = "color", symbol = "symbol"
        static let instructions = "instructions", agent = "agent", collapsed = "collapsed"
        static let all: Set<String> = [id, name, color, symbol, instructions, agent, collapsed]
    }

    init?(json: JSONValue) {
        guard let object = json.objectValue,
            let id = object[Key.id]?.stringValue.flatMap(UUID.init(uuidString:)),
            let name = object[Key.name]?.stringValue.flatMap(Self.cleanName)
        else { return nil }
        self.id = id
        self.name = name
        color = object[Key.color]?.stringValue ?? ""
        symbol = object[Key.symbol]?.stringValue ?? Self.symbols[0]
        instructions = object[Key.instructions]?.stringValue
        agentID = object[Key.agent]?.stringValue.flatMap(UUID.init(uuidString:))
        isCollapsed = object[Key.collapsed]?.boolValue ?? false
        unknown = object.filter { !Key.all.contains($0.key) }
    }

    var json: JSONValue {
        var object = unknown
        object[Key.id] = .string(id.uuidString)
        object[Key.name] = .string(name)
        object[Key.color] = .string(color)
        object[Key.symbol] = .string(symbol)
        if let instructions { object[Key.instructions] = .string(instructions) }
        if let agentID { object[Key.agent] = .string(agentID.uuidString) }
        if isCollapsed { object[Key.collapsed] = .bool(true) }
        return .object(object)
    }
}
