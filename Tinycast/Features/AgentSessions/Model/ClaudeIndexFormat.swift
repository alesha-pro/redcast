import Foundation

/// One transcript's facts as the cache keeps them, so a later open reads only what changed.
struct ClaudeIndexEntry: Codable, Equatable, Sendable {
    /// Relative to the cache's `projectsRoot`.
    var path: String
    var size: Int64
    var modified: Double
    var headDone: Bool
    var session: String?
    var cwd: String?
    var branch: String?
    var entry: String?
    var created: Double?
    var first: String?
    var title: String
    var titleOrigin: AgentSessionTitleOrigin
    var last: String?

    init(
        item: ClaudeListingItem, head: ClaudeTranscriptDecoder.HeadFacts,
        tail: ClaudeTranscriptDecoder.TailFacts
    ) {
        path = item.path
        size = item.size
        modified = item.modified
        headDone = head.isComplete
        session = head.sessionID
        cwd = tail.relocatedCwd ?? head.cwd
        branch = head.branch
        entry = head.entrypoint
        created = head.createdAt?.timeIntervalSince1970
        first = head.firstPrompt
        (title, titleOrigin) = ClaudeTranscriptDecoder.title(head: head, tail: tail)
        last = tail.lastPrompt
    }

    /// A grown file: only its tail is new, and a name it was given earlier still stands.
    func updating(tail: ClaudeTranscriptDecoder.TailFacts, item: ClaudeListingItem) -> ClaudeIndexEntry {
        var updated = self
        updated.size = item.size
        updated.modified = item.modified
        if let relocated = tail.relocatedCwd { updated.cwd = relocated }
        if let last = tail.lastPrompt { updated.last = last }
        if let named = tail.customTitle {
            updated.title = AgentSessionText.oneLine(named, limit: AgentSessionText.titleLimit)
            updated.titleOrigin = .named
        } else if titleOrigin != .named, let generated = tail.aiTitle ?? tail.summary {
            updated.title = AgentSessionText.oneLine(generated, limit: AgentSessionText.titleLimit)
            updated.titleOrigin = .generated
        }
        return updated
    }
}

struct ClaudeIndexFile: Codable, Sendable {
    static let currentVersion = 1
    var version: Int
    var projectsRoot: String
    var entries: [ClaudeIndexEntry]

    init(projectsRoot: String, entries: [ClaudeIndexEntry]) {
        version = Self.currentVersion
        self.projectsRoot = projectsRoot
        self.entries = entries
    }

    /// Nil means rebuild: another version, another root, or bytes that no longer decode.
    static func decode(_ data: Data, projectsRoot: String) -> ClaudeIndexFile? {
        guard let file = try? JSONDecoder().decode(ClaudeIndexFile.self, from: data),
            file.version == currentVersion, file.projectsRoot == projectsRoot
        else { return nil }
        return file
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }
}

struct ClaudeListingItem: Equatable, Sendable {
    let path: String
    let size: Int64
    let modified: Double
}

/// What each transcript needs this open; pure, so the incremental rule is harness-tested.
enum ClaudeRescanPolicy {
    enum Step: Equatable, Sendable { case reuse, tail, full }

    /// Newest first, so a first scan fills the list from the sessions a person looks for.
    static func plan(cached: [String: ClaudeIndexEntry], listing: [ClaudeListingItem])
        -> (steps: [(ClaudeListingItem, Step)], dropped: [String])
    {
        let listed = Set(listing.map(\.path))
        let dropped = cached.keys.filter { !listed.contains($0) }.sorted()
        let steps = listing.sorted { $0.modified > $1.modified }.map { item in
            (item, step(for: item, cached: cached[item.path]))
        }
        return (steps, dropped)
    }

    static func step(for item: ClaudeListingItem, cached: ClaudeIndexEntry?) -> Step {
        guard let cached else { return .full }
        if cached.size == item.size, cached.modified == item.modified { return .reuse }
        guard item.size > cached.size, cached.headDone else { return .full }
        return .tail
    }

    /// Nil for a transcript with nothing to show: no title and no prompt.
    static func session(from entry: ClaudeIndexEntry, root: String) -> AgentSession? {
        let first = entry.first ?? ""
        guard entry.titleOrigin != .untitled || !first.isEmpty else { return nil }
        // The file's name is what `--resume` looks up; a forked transcript still quotes its parent.
        let id = ((entry.path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard !id.isEmpty else { return nil }
        let updated = Date(timeIntervalSince1970: entry.modified)
        return AgentSession(
            source: .claude, sessionID: id, title: entry.title, titleOrigin: entry.titleOrigin,
            firstPrompt: first, lastPrompt: entry.last ?? "", directory: entry.cwd, branch: entry.branch,
            createdAt: entry.created.map(Date.init(timeIntervalSince1970:)) ?? updated,
            updatedAt: updated, host: ClaudeTranscriptDecoder.host(entrypoint: entry.entry),
            transcriptPath: (root as NSString).appendingPathComponent(entry.path))
    }
}
