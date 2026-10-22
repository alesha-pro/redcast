import Foundation

/// A slash command an ACP session offers; ACP sends one as plain prompt text, `/name input`.
struct ACPCommand: Equatable, Identifiable, Sendable {
    let name: String
    let description: String
    let hint: String?

    var id: String { name }

    static let maxCount = 200
    static let maxNameLength = 64
    static let maxDescriptionLength = 200
    static let maxHintLength = 80

    /// `availableCommands`, bounded; a name with a space or a slash could never be typed back.
    static func list(_ value: JSONValue?) -> [ACPCommand] {
        var seen: Set<String> = []
        var commands: [ACPCommand] = []
        for item in value?.arrayValue ?? [] {
            guard commands.count < maxCount, let object = item.objectValue,
                let raw = object["name"]?.stringValue
            else { continue }
            let name = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
            guard isName(name), seen.insert(name.lowercased()).inserted else { continue }
            let hint = object["input"]?.objectValue?["hint"]?.stringValue.map {
                clipped($0, to: maxHintLength)
            }
            commands.append(
                ACPCommand(
                    name: name,
                    description: clipped(object["description"]?.stringValue ?? "", to: maxDescriptionLength),
                    hint: hint?.isEmpty == false ? hint : nil))
        }
        return commands
    }

    /// The name a draft is still typing: after its `/`, before any space; nil once it is not.
    static func typedName(in draft: String) -> Substring? {
        guard draft.first == "/" else { return nil }
        let name = draft.dropFirst()
        return name.contains(where: \.isWhitespace) ? nil : name
    }

    /// Commands the typed name could become: those it starts first, then those it appears in.
    static func matches(for draft: String, in commands: [ACPCommand]) -> [ACPCommand] {
        guard let typed = typedName(in: draft) else { return [] }
        guard !typed.isEmpty else { return commands }
        let leading = commands.filter { $0.name.range(of: typed, options: [.caseInsensitive, .anchored]) != nil }
        let inner = commands.filter {
            $0.name.range(of: typed, options: .caseInsensitive) != nil && !leading.contains($0)
        }
        return leading + inner
    }

    /// The command a turn's text runs: one the session offered, or before any list, any name.
    static func invocation(in text: String, offered: [ACPCommand]) -> String? {
        guard text.first == "/" else { return nil }
        let name = String(text.dropFirst().prefix { !$0.isWhitespace })
        guard isName(name) else { return nil }
        if offered.isEmpty { return name }
        return offered.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.name
    }

    /// What Tab or Return leaves in the draft: the name, and a space for its input.
    var completion: String { "/" + name + " " }

    private static func isName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= maxNameLength
            && !name.contains { $0.isWhitespace || $0 == "/" }
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count <= limit ? line : String(line.prefix(limit - 1)) + "…"
    }
}
