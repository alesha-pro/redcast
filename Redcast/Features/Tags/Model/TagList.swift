import Foundation

/// Fork: the one spelling, matching and listing rule for snippet and quicklink tags.
enum TagList {
    static let maximumLength = 40

    /// Trimmed, `#` dropped, inner whitespace collapsed and commas split; the first spelling wins.
    static func normalized(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for part in raw.flatMap({ $0.split(separator: ",") }) {
            guard let tag = cleaned(part), seen.insert(key(tag)).inserted else { continue }
            result.append(tag)
        }
        return result
    }

    static func cleaned(_ raw: some StringProtocol) -> String? {
        let visible = String(raw).unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var text = String(String.UnicodeScalarView(visible)).trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") { text.removeFirst() }
        let joined = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(maximumLength))
    }

    /// `Work` and `work` are one tag; no locale, so the key is the same on every Mac.
    static func key(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    static func contains(_ tags: [String], _ tag: String) -> Bool {
        let wanted = key(tag)
        return tags.contains { key($0) == wanted }
    }

    /// Every distinct tag across a library, in the order a menu lists them.
    static func library(_ lists: some Sequence<[String]>) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in lists.joined() where seen.insert(key(tag)).inserted {
            result.append(tag)
        }
        return result.sorted { $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedAscending }
    }

    /// Prefix matches first, then the rest that contain the draft; chosen tags are never offered.
    static func suggestions(
        for draft: String, from library: [String], excluding chosen: [String], limit: Int = 6
    ) -> [String] {
        let open = library.filter { !contains(chosen, $0) }
        guard let typed = cleaned(draft).map(key) else { return Array(open.prefix(limit)) }
        let prefixed = open.filter { key($0).hasPrefix(typed) }
        let containing = open.filter { !key($0).hasPrefix(typed) && key($0).contains(typed) }
        return Array((prefixed + containing).prefix(limit))
    }

    /// A list query also finds a row by a tag; `#wo` matches only tags that start with `wo`.
    static func matches(query: String, tags: [String]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            guard let typed = cleaned(trimmed).map(key) else { return !tags.isEmpty }
            return tags.contains { key($0).hasPrefix(typed) }
        }
        guard let typed = cleaned(trimmed).map(key) else { return false }
        return tags.contains { key($0).contains(typed) }
    }

    /// A list row's search: `#…` asks its tags alone, anything else its texts or its tags.
    static func row(matching query: String, texts: [String?], tags: [String]) -> Bool {
        if query.trimmingCharacters(in: .whitespaces).hasPrefix("#") { return matches(query: query, tags: tags) }
        return texts.contains { $0?.localizedCaseInsensitiveContains(query) == true }
            || matches(query: query, tags: tags)
    }

    /// The rows a ⌘P filter leaves; nil keeps them all.
    static func filter<Row>(_ rows: [Row], by tag: String?, tags: (Row) -> [String]) -> [Row] {
        guard let tag else { return rows }
        return rows.filter { contains(tags($0), tag) }
    }

    /// A SQLite column's text: a JSON array, nil when there is nothing to store.
    static func column(_ tags: [String]) -> String? {
        guard !tags.isEmpty, let data = try? JSONEncoder().encode(tags) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    /// Reads any build's column; text that isn't a JSON array reads as a comma list.
    static func tags(fromColumn text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        if let decoded = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) {
            return normalized(decoded)
        }
        return normalized([text])
    }

    /// Raycast and hand-written exports: strings, `{name}` or `{title}` objects, or one comma list.
    static func imported(_ value: Any?) -> [String] {
        switch value {
        case let text as String:
            return normalized([text])
        case let list as [Any]:
            return normalized(
                list.compactMap { item in
                    if let text = item as? String { return text }
                    let object = item as? [String: Any]
                    return (object?["name"] ?? object?["title"]) as? String
                })
        default:
            return []
        }
    }
}
