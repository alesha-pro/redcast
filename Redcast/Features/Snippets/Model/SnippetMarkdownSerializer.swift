import Foundation

struct SnippetMarkdownSerializer {
    enum ParseError: Error, LocalizedError, Equatable {
        case invalidFrontmatter(fileURL: URL, line: Int, reason: String)

        var errorDescription: String? {
            switch self {
            case .invalidFrontmatter(let fileURL, let line, let reason):
                return "\(fileURL.path):\(line): \(reason)"
            }
        }
    }

    static func parse(content: String, fileURL: URL) throws -> Snippet {
        let lines = sourceLines(in: content)
        guard lines.first?.text == "---" else {
            return Snippet(name: defaultName(for: fileURL), text: content)
        }

        guard let closingIndex = lines.dropFirst().firstIndex(where: { $0.text == "---" }) else {
            throw parseError(fileURL, line: 1, String(localized: "Missing closing frontmatter delimiter"))
        }

        var name: String?
        var keyword: String?
        var isEnabled = true
        var showsConfirmation = false
        var seenKeys = Set<String>()
        var tags: [String] = []  // Fork: Tags
        var unknown: [String] = []  // Fork: Tags

        var lineIndex = 0  // Fork: a block value consumes the lines under its key.
        while lineIndex + 1 < closingIndex {
            lineIndex += 1
            let line = lines[lineIndex]
            let lineNumber = lineIndex + 1
            guard !line.text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let separator = line.text.firstIndex(of: ":") else {
                throw parseError(
                    fileURL, line: lineNumber, String(localized: "Expected a key and value separated by ':'"))
            }

            let rawKey = line.text[..<separator].trimmingCharacters(in: .whitespaces)
            let rawValue = line.text[line.text.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            let known = canonicalKey(for: rawKey)
            let block = blockLines(after: &lineIndex, below: closingIndex, in: lines, for: known)  // Fork
            guard let key = known else {
                // Fork: an unknown key and its block are kept as written; only retired keys are refused.
                guard retiredKeys.contains(rawKey.lowercased()) else {
                    unknown += [String(line.text)] + block.map(String.init)
                    continue
                }
                throw parseError(
                    fileURL, line: lineNumber, String(localized: "Unsupported frontmatter key '\(rawKey)'"))
            }
            guard seenKeys.insert(key).inserted else {
                throw parseError(
                    fileURL, line: lineNumber, String(localized: "Duplicate frontmatter key '\(key)'"))
            }

            switch key {
            case "name":
                let decoded = try decodeScalar(rawValue, fileURL: fileURL, line: lineNumber)
                // A blank name reads as absent, so the filename fallback still yields a label.
                name = decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : decoded
            case "keyword":
                keyword = try decodeScalar(rawValue, fileURL: fileURL, line: lineNumber)
            case "enabled":
                isEnabled = try decodeBoolean(rawValue, fileURL: fileURL, line: lineNumber)
            case "show_confirmation":
                showsConfirmation = try decodeBoolean(rawValue, fileURL: fileURL, line: lineNumber)
            case TagFrontmatter.key:  // Fork: Tags
                tags = TagFrontmatter.decode(rawValue, items: block)
            default:
                preconditionFailure("Canonical keys are exhaustively handled")
            }
        }

        let bodyStart = lines[closingIndex].endIncludingTerminator
        return Snippet(
            name: name ?? defaultName(for: fileURL),
            text: String(content[bodyStart...]),
            keyword: keyword,
            isEnabled: isEnabled,
            showsConfirmation: showsConfirmation,
            tags: tags, unknownFrontmatter: unknown  // Fork: Tags
        )
    }

    static func serialize(_ snippet: Snippet) -> String {
        var lines = [
            "---",
            "name: \(encodeScalar(snippet.name))"
        ]
        if let keyword = snippet.keyword {
            lines.append("keyword: \(encodeScalar(keyword))")
        }
        if !snippet.tags.isEmpty {  // Fork: Tags
            lines.append("\(TagFrontmatter.key): \(TagFrontmatter.encode(snippet.tags))")
        }
        lines.append("enabled: \(snippet.isEnabled)")
        lines.append("show_confirmation: \(snippet.showsConfirmation)")
        lines += snippet.unknownFrontmatter  // Fork: Tags
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + snippet.text
    }

    static func slug(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var slug = name.lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        if slug.isEmpty { slug = "snippet" }
        return slug
    }

    private struct SourceLine {
        let text: Substring
        let endIncludingTerminator: String.Index
    }

    private static func sourceLines(in content: String) -> [SourceLine] {
        var lines: [SourceLine] = []
        var lineStart = content.startIndex
        var index = content.startIndex

        while index < content.endIndex {
            let character = content[index]
            guard character == "\n" || character == "\r" || character == "\r\n" else {
                index = content.index(after: index)
                continue
            }

            var terminatorEnd = content.index(after: index)
            if character == "\r", terminatorEnd < content.endIndex, content[terminatorEnd] == "\n" {
                terminatorEnd = content.index(after: terminatorEnd)
            }
            lines.append(SourceLine(text: content[lineStart..<index], endIncludingTerminator: terminatorEnd))
            lineStart = terminatorEnd
            index = terminatorEnd
        }

        if lineStart < content.endIndex || lines.isEmpty {
            lines.append(SourceLine(text: content[lineStart...], endIncludingTerminator: content.endIndex))
        }
        return lines
    }

    private static func canonicalKey(for rawKey: String) -> String? {
        let key = rawKey.lowercased()
        switch key {
        case "name", "keyword", "enabled", "show_confirmation", TagFrontmatter.key:  // Fork: Tags
            return key
        default:
            return nil
        }
    }

    /// Fork: keys that once meant something, so a file still carrying one is reported, not half-read.
    private static let retiredKeys: Set = ["showinlauncher", "category", "show_in_launcher", "show_hud"]

    /// Fork: only a key whose value may be a block takes the indented or `- ` lines below it.
    private static func blockLines(
        after index: inout Int, below end: Int, in lines: [SourceLine], for key: String?
    ) -> [Substring] {
        guard key == nil || key == TagFrontmatter.key else { return [] }
        var block: [Substring] = []
        while index + 1 < end, TagFrontmatter.isContinuation(lines[index + 1].text) {
            index += 1
            block.append(lines[index].text)
        }
        return block
    }

    private static func decodeScalar(_ value: String, fileURL: URL, line: Int) throws -> String {
        let scalars = value.unicodeScalars
        guard scalars.first == "\"" else {
            throw parseError(fileURL, line: line, String(localized: "String values must use double quotes"))
        }

        var decoded = ""
        var index = scalars.index(after: scalars.startIndex)
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\"" {
                let trailing = scalars[scalars.index(after: index)...]
                guard trailing.allSatisfy({ $0 == " " || $0 == "\t" }) else {
                    throw parseError(
                        fileURL, line: line, String(localized: "Unexpected text after quoted value"))
                }
                return decoded
            }
            if scalar == "\\" {
                let escapeIndex = scalars.index(after: index)
                guard escapeIndex < scalars.endIndex else {
                    throw parseError(fileURL, line: line, String(localized: "Unterminated escape sequence"))
                }
                switch scalars[escapeIndex] {
                case "\\": decoded.append("\\")
                case "\"": decoded.append("\"")
                case "n": decoded.append("\n")
                case "r": decoded.append("\r")
                case "t": decoded.append("\t")
                default:
                    throw parseError(fileURL, line: line, String(localized: "Unsupported escape sequence"))
                }
                index = scalars.index(after: escapeIndex)
                continue
            }
            guard scalar != "\n" && scalar != "\r" && scalar != "\t" else {
                throw parseError(fileURL, line: line, String(localized: "Control characters must be escaped"))
            }
            decoded.unicodeScalars.append(scalar)
            index = scalars.index(after: index)
        }
        throw parseError(fileURL, line: line, String(localized: "Unterminated quoted value"))
    }

    private static func decodeBoolean(_ value: String, fileURL: URL, line: Int) throws -> Bool {
        switch value {
        case "true": return true
        case "false": return false
        default:
            throw parseError(
                fileURL, line: line, String(localized: "Boolean values must be exactly 'true' or 'false'"))
        }
    }

    private static func encodeScalar(_ value: String) -> String {
        var encoded = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": encoded += "\\\\"
            case "\"": encoded += "\\\""
            case "\n": encoded += "\\n"
            case "\r": encoded += "\\r"
            case "\t": encoded += "\\t"
            default: encoded.unicodeScalars.append(scalar)
            }
        }
        encoded.append("\"")
        return encoded
    }

    private static func defaultName(for fileURL: URL) -> String {
        fileURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .capitalized(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func parseError(_ fileURL: URL, line: Int, _ reason: String) -> ParseError {
        .invalidFrontmatter(fileURL: fileURL, line: line, reason: reason)
    }
}
