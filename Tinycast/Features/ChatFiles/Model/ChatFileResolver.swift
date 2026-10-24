import Foundation

/// What a finished reply is resolved against: its chat's folder and what its calls touched.
struct ChatFileRequest: Hashable, Sendable {
    let reply: String
    /// The agent's folder, the cwd its tools and an ACP agent run in; nil for a plain chat.
    let directory: String?
    let home: String
    /// Each call's row title, as `write_file: out/card.png` or `Write /tmp/card.png`.
    let toolTitles: [String]
    /// The files an ACP agent's diffs changed.
    let diffPaths: [String]
}

/// A reply's mentions that exist, by the key the renderer meets each by, and its Files strip.
struct ChatFileLinks: Equatable, Sendable {
    var byMention: [String: ChatFileItem] = [:]
    /// What the reply named, in its order, then what its calls wrote; each item once.
    var files: [ChatFileItem] = []

    static let empty = ChatFileLinks()

    var isEmpty: Bool { byMention.isEmpty && files.isEmpty }

    /// Room for a row of chips; the rest wait behind a `+N` chip.
    static let stripLimit = 6

    static func strip(_ files: [ChatFileItem], expanded: Bool) -> (shown: [ChatFileItem], hidden: Int) {
        guard !expanded, files.count > stripLimit else { return (files, 0) }
        return (Array(files.prefix(stripLimit - 1)), files.count - (stripLimit - 1))
    }
}

/// A bare name is looked for beside a folder the reply named, then in the chat's, then in calls.
enum ChatFileResolver {
    /// What one reply's calls may add to its strip, so a bulk edit does not bury the result.
    static let writtenLimit = 16
    /// Folders a bare name is tried in, so a long reply never costs more than a few lookups each.
    static let folderLimit = 4

    static func resolve(_ request: ChatFileRequest, stat: (String) -> ChatFileStat?) -> ChatFileLinks {
        var memo: [String: ChatFileStat?] = [:]
        func item(at path: String) -> ChatFileItem? {
            let found: ChatFileStat?
            if let known = memo[path] {
                found = known
            } else {
                found = stat(path)
                memo[path] = found
            }
            return found.map { ChatFileItem(path: path, kind: ChatFileOpenPolicy.kind(of: path, $0)) }
        }
        let mentions = ChatFileMentions.scan(request.reply)
        var links = ChatFileLinks()
        var folders: [String] = []
        for mention in mentions where !mention.isBareName {
            guard let path = absolute(mention.text, base: request.directory, home: request.home),
                let found = item(at: path)
            else { continue }
            links.byMention[mention.text] = found
            if found.kind == .folder { folders.append(found.path) }
        }
        let touched = request.toolTitles.flatMap { ChatFileMentions.toolPaths($0).paths }
            .compactMap { absolute($0, base: request.directory, home: request.home) }
        for mention in mentions where links.byMention[mention.text] == nil {
            let named = folders.prefix(folderLimit)
            var candidates = named.compactMap { absolute(mention.text, base: $0, home: request.home) }
            if mention.isBareName {
                if let directory = request.directory { candidates.append(join(directory, mention.text)) }
                candidates.append(contentsOf: touched.filter { $0.hasSuffix("/" + mention.text) })
            }
            for candidate in candidates {
                guard let found = item(at: candidate) else { continue }
                links.byMention[mention.text] = found
                break
            }
        }
        var seen = Set<String>()
        links.files = mentions.compactMap { links.byMention[$0.text] }
            .filter { seen.insert($0.path).inserted }
        let written = request.diffPaths + request.toolTitles.compactMap { title in
            let paths = ChatFileMentions.toolPaths(title)
            return paths.writes ? paths.paths.first : nil
        }
        for path in written.prefix(writtenLimit) {
            guard let absolute = absolute(path, base: request.directory, home: request.home),
                !seen.contains(absolute), let found = item(at: absolute)
            else { continue }
            seen.insert(absolute)
            links.files.append(found)
        }
        return links
    }

    /// `~` and relative paths made absolute, with `.`, `..` and repeated slashes folded away.
    static func absolute(_ path: String, base: String?, home: String) -> String? {
        if path == "~" { return normalised(home) }
        if path.hasPrefix("~/") { return normalised(join(home, String(path.dropFirst(2)))) }
        if path.hasPrefix("/") { return normalised(path) }
        guard let base, base.hasPrefix("/") else { return nil }
        return normalised(join(base, path))
    }

    private static func join(_ base: String, _ path: String) -> String {
        base.hasSuffix("/") ? base + path : base + "/" + path
    }

    private static func normalised(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if parts.popLast() == nil { return nil }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
