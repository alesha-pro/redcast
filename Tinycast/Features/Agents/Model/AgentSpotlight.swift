import Foundation

/// `search_files`'s Spotlight mode: the `mdfind` query from the model's words, and what it shows.
nonisolated struct AgentSpotlightQuery: Equatable, Sendable {
    static let mode = "spotlight"
    static let maxTerms = 8
    static let maxTermLength = 100
    static let maxShown = 50

    /// Content types by the names the model may pass as `kind`; each matches its whole subtree.
    static let kinds: [String: [String]] = [
        "pdf": ["com.adobe.pdf"],
        "document": [
            "com.adobe.pdf", "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
            "public.rtf", "com.apple.rtfd", "org.oasis-open.opendocument.text",
            "com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.pages"
        ],
        "spreadsheet": ["public.spreadsheet"],
        "presentation": ["public.presentation"],
        "image": ["public.image"],
        "audio": ["public.audio"],
        "video": ["public.movie"],
        "text": ["public.plain-text"],
        "code": ["public.source-code"],
        "folder": ["public.folder"],
        "archive": ["public.archive"]
    ]

    struct Failure: Error, Equatable, Sendable {
        let message: String
    }

    let terms: [String]
    let kind: String?
    /// `YYYY-MM-DD`, checked digit by digit, so nothing but a date reaches the query.
    let modifiedAfter: String?
    let namesOnly: Bool

    /// The model's arguments, or what to tell it when they do not make a query.
    static func parse(_ arguments: [String: JSONValue]) -> Result<Self, Failure> {
        let terms = Self.terms(in: arguments["pattern"]?.stringValue ?? "")
        let kind = arguments["kind"]?.stringValue?.lowercased().trimmingCharacters(in: .whitespaces)
        if let kind, !kind.isEmpty, kinds[kind] == nil {
            return .failure(Failure(message: "kind is one of: " + kinds.keys.sorted().joined(separator: ", ") + "."))
        }
        let date = arguments["modified_after"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        if let date, !date.isEmpty, !isDate(date) {
            return .failure(Failure(message: "modified_after takes a date as YYYY-MM-DD."))
        }
        let query = Self(
            terms: terms, kind: kind?.isEmpty == false ? kind : nil,
            modifiedAfter: date?.isEmpty == false ? date : nil,
            namesOnly: arguments["names_only"]?.boolValue ?? false)
        guard !terms.isEmpty || query.kind != nil || query.modifiedAfter != nil else {
            return .failure(Failure(message: "Give words to find in pattern, or a kind or modified_after."))
        }
        return .success(query)
    }

    /// Words, or phrases in double quotes; each must match a name, a title or the indexed text.
    static func terms(in pattern: String) -> [String] {
        var terms: [String] = []
        for (index, piece) in pattern.split(separator: "\"", omittingEmptySubsequences: false).enumerated() {
            let words = index.isMultiple(of: 2) ? piece.split(whereSeparator: \.isWhitespace) : [piece]
            for word in words {
                let term = String(word.filter { !isControl($0) }).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty, term.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                terms.append(String(term.prefix(maxTermLength)))
            }
        }
        return Array(terms.prefix(maxTerms))
    }

    /// The query language `mdfind` and Spotlight share; `cd` ignores case and diacritics.
    var query: String {
        var clauses = terms.map { term in
            let value = Self.escaped(term)
            var fields = ["kMDItemFSName == \"*\(value)*\"cd", "kMDItemTitle == \"*\(value)*\"cd"]
            if !namesOnly { fields.append("kMDItemTextContent == \"\(value)*\"cdw") }
            return "(" + fields.joined(separator: " || ") + ")"
        }
        if let kind, let types = Self.kinds[kind] {
            clauses.append(
                "(" + types.map { "kMDItemContentTypeTree == \"\($0)\"" }.joined(separator: " || ") + ")")
        }
        if let modifiedAfter { clauses.append("kMDItemFSContentChangeDate >= $time.iso(\(modifiedAfter))") }
        return clauses.joined(separator: " && ")
    }

    /// One `-onlyin` per root; the query is a single argument, never read by a shell.
    func arguments(in roots: [String]) -> [String] {
        roots.flatMap { ["-onlyin", $0] } + [query]
    }

    /// Inside a quoted value only a backslash, a quote and the wildcards mean anything.
    static func escaped(_ text: String) -> String {
        var escaped = ""
        for character in text where !character.isNewline && !isControl(character) {
            if "\\\"*?".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// A NUL makes no argument a process can be given, and no control character names a file.
    private static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    private static func isDate(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.map(\.count) == [4, 2, 2],
            parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
            let month = Int(parts[1]), let day = Int(parts[2])
        else { return false }
        return (1...12).contains(month) && (1...31).contains(day)
    }

    /// What a path found is shown with, newest first.
    struct Hit: Equatable, Sendable {
        let path: String
        let isFolder: Bool
        let size: Int?
        let modified: Date?
    }

    /// Hidden paths and `~/Library` (mail, messages, caches) stay out unless a search began there;
    /// iCloud Drive and the cloud folders kept in it are the user's documents, so they are shown.
    static func isShown(_ path: String, roots: [String], home: String) -> Bool {
        guard let root = roots.first(where: { AgentPathPolicy.isInside(path, root: $0) }) else { return false }
        let relative = path.dropFirst(root.count).split(separator: "/")
        guard !relative.contains(where: { $0.hasPrefix(".") }) else { return false }
        let library = (home as NSString).appendingPathComponent("Library")
        guard AgentPathPolicy.isInside(path, root: library), !AgentPathPolicy.isInside(root, root: library) else {
            return true
        }
        if AgentPathPolicy.isInside(path, root: library + "/CloudStorage") { return true }
        let drive = library + "/Mobile Documents"
        guard AgentPathPolicy.isInside(path, root: drive) else { return false }
        // iCloud Drive's own folder, and each app's Documents folder, as Finder lists them.
        let inner = path.dropFirst(drive.count).split(separator: "/")
        return inner.first == "com~apple~CloudDocs" || (inner.count > 2 && inner[1] == "Documents")
    }

    /// One line a file, newest first, and what was left out.
    static func listing(_ hits: [Hit], matched: Int, cut: Bool, timeZone: TimeZone) -> String {
        guard !hits.isEmpty else {
            return "Spotlight found nothing. It indexes only folders it was allowed into, so a search with "
                + "mode text may still find what is there."
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sorted = hits.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        var lines = sorted.prefix(maxShown).map { hit in
            let date = hit.modified.map { day($0, calendar: calendar) } ?? "          "
            let size = hit.isFolder ? "folder" : hit.size.map(Self.size) ?? "?"
            return "\(date)  \(size.padding(toLength: 8, withPad: " ", startingAt: 0))  \(hit.path)"
        }
        let more = max(matched, hits.count) - lines.count
        if more > 0 || cut {
            lines.append(
                "… " + (cut ? "more" : "\(more) more") + " matched; narrow the words, kind, "
                    + "modified_after or path.")
        }
        return lines.joined(separator: "\n")
    }

    private static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func size(_ bytes: Int) -> String {
        switch bytes {
        case ..<1_024: "\(bytes) B"
        case ..<1_048_576: "\(bytes / 1_024) KB"
        case ..<1_073_741_824: String(format: "%.1f MB", Double(bytes) / 1_048_576)
        default: String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        }
    }
}
