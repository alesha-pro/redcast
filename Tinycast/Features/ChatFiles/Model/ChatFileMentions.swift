import Foundation

/// A path as a reply wrote it: the key the renderer meets it by, and how it was written.
struct ChatFileMention: Hashable, Sendable {
    enum Form: Hashable, Sendable {
        case link
        case code
        case bare
    }

    let text: String
    let form: Form

    /// No folder in it, so it is looked up beside what the reply already named.
    var isBareName: Bool { !text.contains("/") }
}

/// Where a reply names files: Markdown links, inline code, and bare absolute or `~` paths.
enum ChatFileMentions {
    /// Past this a reply is a listing rather than a few results, and the rest stay plain text.
    static let limit = 48
    /// Longer than any path a reply cites, so a code span of prose is never looked up.
    static let maxLength = 1024

    /// Every mention in the order the reply wrote it, each text once; fenced code is a sample.
    static func scan(_ reply: String) -> [ChatFileMention] {
        let prose = blanking(reply, #/```[\s\S]*?(```|$)/#)
        var found: [(offset: Int, mention: ChatFileMention)] = []
        for match in prose.matches(of: #/\[[^\]\n]*\]\((<[^>\n]+>|[^)\s]+)\)/#) {
            var target = Substring(match.output.1)
            if target.hasPrefix("<") { target = target.dropFirst().dropLast() }
            guard let key = linkKey(String(target)) else { continue }
            found.append((offset(of: match.range, in: prose), ChatFileMention(text: key, form: .link)))
        }
        let unlinked = blanking(prose, #/\[[^\]\n]*\]\((<[^>\n]+>|[^)\s]+)\)/#)
        for match in unlinked.matches(of: #/`([^`\n]+)`/#) {
            guard let key = codeKey(String(match.output.1)) else { continue }
            found.append((offset(of: match.range, in: unlinked), ChatFileMention(text: key, form: .code)))
        }
        let plain = blanking(unlinked, #/`[^`\n]+`/#)
        for range in barePaths(in: plain) {
            let mention = ChatFileMention(text: String(plain[range]), form: .bare)
            found.append((offset(of: range, in: plain), mention))
        }
        var seen = Set<String>()
        return found.sorted { $0.offset < $1.offset }
            .map(\.mention)
            .filter { seen.insert($0.text).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// A link's target as a path: `file:` URLs and scheme-less targets; web and app links are not.
    static func linkKey(_ target: String) -> String? {
        if target.lowercased().hasPrefix("file:") {
            guard let path = URL(string: target)?.path(percentEncoded: false), !path.isEmpty else {
                return nil
            }
            return trimmed(path)
        }
        guard target.firstMatch(of: #/^[A-Za-z][A-Za-z0-9+.\-]*:/#) == nil else { return nil }
        let decoded = target.removingPercentEncoding ?? target
        let path = String(decoded.prefix { $0 != "#" && $0 != "?" })
        guard looksLikePath(path) else { return nil }
        return trimmed(path)
    }

    /// An inline code span that reads as a path, without a `:line` or `:line:column` suffix.
    static func codeKey(_ code: String) -> String? {
        var text = code.trimmingCharacters(in: .whitespaces)
        if text.count > 1, let first = text.first, first == "\"" || first == "'", text.last == first {
            text = String(text.dropFirst().dropLast())
        }
        if text.lowercased().hasPrefix("file:") { return linkKey(text) }
        guard text.count <= maxLength, !text.contains("://"), looksLikePath(text) else { return nil }
        guard text.rangeOfCharacter(from: CharacterSet(charactersIn: "`$|;&<>*?{}=\"\n\t")) == nil else {
            return nil
        }
        return trimmed(text)
    }

    /// Absolute and `~/` paths in prose; a slash after a word, as in `and/or`, starts none.
    static func barePaths(in text: String) -> [Range<String.Index>] {
        guard text.contains("/") else { return [] }
        var ranges: [Range<String.Index>] = []
        for match in text.matches(of: #/~?/[\w.\-+@%~/]+/#) {
            if match.range.lowerBound > text.startIndex {
                let before = text[text.index(before: match.range.lowerBound)]
                guard !(before.isLetter || before.isNumber || "/~.:-_\\".contains(before)) else { continue }
            }
            var end = match.range.upperBound
            while end > match.range.lowerBound, ".,:;!?".contains(text[text.index(before: end)]) {
                end = text.index(before: end)
            }
            let path = text[match.range.lowerBound..<end]
            guard path.count > 1, path != "~/", path.count <= maxLength else { continue }
            ranges.append(match.range.lowerBound..<end)
        }
        return ranges
    }

    /// The paths a call's row names, and whether the call wrote its first one.
    static func toolPaths(_ title: String) -> (paths: [String], writes: Bool) {
        let name: Substring
        let rest: Substring
        if let colon = title.range(of: ": "), !title[..<colon.lowerBound].contains(" ") {
            name = title[..<colon.lowerBound]
            rest = title[colon.upperBound...]
        } else if let space = title.firstIndex(of: " ") {
            name = title[..<space]
            rest = title[title.index(after: space)...]
        } else {
            return ([], false)
        }
        let paths = rest.split(whereSeparator: \.isWhitespace).compactMap { token -> String? in
            guard !token.hasSuffix("…") else { return nil }
            let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "`'\",;()"))
            guard !bare.hasPrefix("-"), let key = codeKey(bare) else { return nil }
            return key
        }
        return (paths, writers.contains(name.lowercased()) && !paths.isEmpty)
    }

    /// Calls whose first path is the file they wrote: Tinycast's own, and ACP agents' titles.
    private static let writers: Set<String> = [
        "write_file", "edit_file", "write", "edit", "multiedit", "create", "notebookedit"
    ]

    /// A folder in it, or a name with an extension: `README.md`, `out/`, `~/Desktop`.
    private static func looksLikePath(_ text: String) -> Bool {
        guard !text.isEmpty, !text.hasPrefix("-") else { return false }
        if text.contains("/") { return text != "/" }
        return text.firstMatch(of: #/[^.\s]\.[A-Za-z0-9]{1,10}$/#) != nil
    }

    private static func trimmed(_ path: String) -> String {
        var text = path
        if let suffix = text.firstMatch(of: #/:\d+(:\d+)?$/#) { text.removeSubrange(suffix.range) }
        return text
    }

    /// Replaced by spaces of its length, so the offsets of what follows still order the mentions.
    private static func blanking<Output>(_ text: String, _ pattern: Regex<Output>) -> String {
        text.replacing(pattern) { match in String(repeating: " ", count: text[match.range].count) }
    }

    private static func offset(of range: Range<String.Index>, in text: String) -> Int {
        text.distance(from: text.startIndex, to: range.lowerBound)
    }
}
