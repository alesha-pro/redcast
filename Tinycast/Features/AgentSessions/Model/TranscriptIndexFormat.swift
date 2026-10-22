import Foundation

/// One Claude Code or Gemini CLI transcript as its cache keeps it, so an open reads only what changed.
struct TranscriptIndexEntry: Codable, Equatable, Sendable {
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
        item: TranscriptListingItem, head: ClaudeTranscriptDecoder.HeadFacts,
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

    /// `entry` marks a subagent's chat, which is kept so the cache remembers it is not a session.
    init(item: TranscriptListingItem, gemini head: GeminiChatDecoder.HeadFacts, tail: GeminiChatDecoder.TailFacts) {
        path = item.path
        size = item.size
        modified = item.modified
        headDone = head.isComplete
        session = head.sessionID
        entry = head.isSubagent ? TranscriptRescanPolicy.subagent : nil
        created = head.createdAt?.timeIntervalSince1970
        first = head.firstPrompt
        (title, titleOrigin) = GeminiChatDecoder.title(head: head, tail: tail)
        last = tail.lastPrompt
    }

    /// A grown Gemini chat: a new summary retitles it, a new prompt is the last one.
    func updating(gemini tail: GeminiChatDecoder.TailFacts, item: TranscriptListingItem) -> TranscriptIndexEntry {
        var updated = self
        updated.size = item.size
        updated.modified = item.modified
        if let last = tail.lastPrompt { updated.last = last }
        if let summary = tail.summary {
            updated.title = AgentSessionText.oneLine(summary, limit: AgentSessionText.titleLimit)
            updated.titleOrigin = .generated
        }
        return updated
    }

    /// A grown file: only its tail is new, and a name it was given earlier still stands.
    func updating(tail: ClaudeTranscriptDecoder.TailFacts, item: TranscriptListingItem) -> TranscriptIndexEntry {
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

struct TranscriptIndexFile: Codable, Sendable {
    static let currentVersion = 1
    var version: Int
    var projectsRoot: String
    var entries: [TranscriptIndexEntry]

    init(projectsRoot: String, entries: [TranscriptIndexEntry]) {
        version = Self.currentVersion
        self.projectsRoot = projectsRoot
        self.entries = entries
    }

    /// Nil means rebuild: another version, another root, or bytes that no longer decode.
    static func decode(_ data: Data, projectsRoot: String) -> TranscriptIndexFile? {
        guard let file = try? JSONDecoder().decode(TranscriptIndexFile.self, from: data),
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

struct TranscriptListingItem: Equatable, Sendable {
    let path: String
    let size: Int64
    let modified: Double
}

/// A listing and, for Gemini, the folder each project's chats belong to (`<slug>/.project_root`).
struct TranscriptListing: Equatable, Sendable {
    var items: [TranscriptListingItem] = []
    var projects: [String: String] = [:]

    /// The project folder an item sits in: its path's first component.
    func directory(of item: String) -> String? {
        item.split(separator: "/", maxSplits: 1).first.flatMap { projects[String($0)] }
    }
}

/// What each transcript needs this open; pure, so the incremental rule is harness-tested.
enum TranscriptRescanPolicy {
    enum Step: Equatable, Sendable { case reuse, tail, full }

    static let subagent = "subagent"

    /// Newest first, so a first scan fills the list from the sessions a person looks for.
    static func plan(cached: [String: TranscriptIndexEntry], listing: [TranscriptListingItem])
        -> (steps: [(TranscriptListingItem, Step)], dropped: [String])
    {
        let listed = Set(listing.map(\.path))
        let dropped = cached.keys.filter { !listed.contains($0) }.sorted()
        let steps = listing.sorted { $0.modified > $1.modified }.map { item in
            (item, step(for: item, cached: cached[item.path]))
        }
        return (steps, dropped)
    }

    /// A legacy Gemini `.json` is one object, so a changed one is read whole again.
    static func step(for item: TranscriptListingItem, cached: TranscriptIndexEntry?) -> Step {
        guard let cached else { return .full }
        if cached.size == item.size, cached.modified == item.modified { return .reuse }
        guard item.size > cached.size, cached.headDone, !item.path.hasSuffix(".json") else { return .full }
        return .tail
    }

    /// Nil for a transcript with nothing to show: no title and no prompt.
    static func claudeSession(from entry: TranscriptIndexEntry, root: String) -> AgentSession? {
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

    /// Gemini names its files by date, so the id is the one the file's first line holds.
    static func geminiSession(from entry: TranscriptIndexEntry, root: String, directory: String?) -> AgentSession? {
        let first = entry.first ?? ""
        guard entry.entry != subagent, let id = entry.session, !id.isEmpty,
            entry.titleOrigin != .untitled || !first.isEmpty
        else { return nil }
        let updated = Date(timeIntervalSince1970: entry.modified)
        return AgentSession(
            source: .gemini, sessionID: id, title: entry.title, titleOrigin: entry.titleOrigin, firstPrompt: first,
            lastPrompt: entry.last ?? "", directory: directory,
            createdAt: entry.created.map(Date.init(timeIntervalSince1970:)) ?? updated, updatedAt: updated,
            host: .terminal, transcriptPath: (root as NSString).appendingPathComponent(entry.path))
    }
}
