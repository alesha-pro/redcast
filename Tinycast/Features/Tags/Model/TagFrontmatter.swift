import Foundation

/// Fork: a snippet's `tags:` key, read leniently and written as a flow list of quoted strings.
enum TagFrontmatter {
    static let key = "tags"

    static func encode(_ tags: [String]) -> String {
        "[" + tags.map(quoted).joined(separator: ", ") + "]"
    }

    /// `value` is what follows the colon; `items` are block-list lines (`  - work`) under the key.
    static func decode(_ value: String, items: [Substring] = []) -> [String] {
        var raw = splitFlow(value.trimmingCharacters(in: .whitespaces))
        for item in items {
            var text = item.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("-") { text.removeFirst() }
            raw += splitFlow(text.trimmingCharacters(in: .whitespaces))
        }
        return TagList.normalized(raw)
    }

    /// An indented or `- ` line belongs to the key above it rather than starting one of its own.
    static func isContinuation(_ line: Substring) -> Bool {
        guard let first = line.first else { return false }
        return first == " " || first == "\t" || line.hasPrefix("- ") || line == "-"
    }

    private static func splitFlow(_ text: String) -> [String] {
        var body = Substring(text)
        if body.hasPrefix("[") { body = body.dropFirst() }
        if body.hasSuffix("]") { body = body.dropLast() }
        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        for character in body {
            if escaping {
                current.append(unescaped(character))
                escaping = false
            } else if quote != nil, character == "\\" {
                escaping = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "," {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        items.append(current)
        return items
    }

    private static func unescaped(_ character: Character) -> Character {
        switch character {
        case "n", "r", "t": return " "
        default: return character
        }
    }

    private static func quoted(_ tag: String) -> String {
        "\"" + tag.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}
