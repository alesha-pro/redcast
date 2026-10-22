import Foundation

/// File listing and bounded reads for agent histories, plus the transcript caches; all off-main.
enum AgentSessionsScanner {
    static let batchSize = 32
    static let previewLimit = 8
    static let eventHeadCap = 16 * 1_024
    private static let chunk = 16 * 1_024

    private static let listingKeys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]

    @concurrent static func listClaude(root: URL) async -> [TranscriptListingItem] {
        var items: [TranscriptListingItem] = []
        for project in folders(in: root) {
            guard !Task.isCancelled else { return [] }
            // Depth two only: a subagent's transcript sits a folder deeper and is not a session.
            for file in files(in: project) where file.pathExtension == "jsonl" {
                guard let item = item(file, path: project.lastPathComponent + "/" + file.lastPathComponent) else {
                    continue
                }
                items.append(item)
            }
        }
        return items
    }

    /// `<project>/chats/session-*`; a subagent's chat sits a folder deeper and is not a session.
    @concurrent static func listGemini(root: URL) async -> TranscriptListing {
        var listing = TranscriptListing()
        for project in folders(in: root) {
            guard !Task.isCancelled else { return TranscriptListing() }
            let name = project.lastPathComponent
            let chats = files(in: project.appending(path: "chats", directoryHint: .isDirectory)).filter { file in
                file.lastPathComponent.hasPrefix("session-") && ["json", "jsonl"].contains(file.pathExtension)
            }
            guard !chats.isEmpty else { continue }
            listing.projects[name] = projectRoot(project)
            listing.items += chats.compactMap { item($0, path: name + "/chats/" + $0.lastPathComponent) }
        }
        return listing
    }

    /// One batch of planned steps; `reuse` steps are the caller's and never reach here.
    @concurrent static func scan(
        _ steps: [(TranscriptListingItem, TranscriptRescanPolicy.Step)], cached: [String: TranscriptIndexEntry],
        root: URL, source: AgentSource = .claude
    ) async -> [TranscriptIndexEntry] {
        var entries: [TranscriptIndexEntry] = []
        for (item, step) in steps {
            guard !Task.isCancelled else { break }
            let url = root.appending(path: item.path, directoryHint: .notDirectory)
            switch (step, source) {
            case (.reuse, _):
                if let entry = cached[item.path] { entries.append(entry) }
            case (.tail, .gemini):
                guard let entry = cached[item.path] else { continue }
                entries.append(entry.updating(gemini: geminiTail(at: url), item: item))
            case (.tail, _):
                guard let entry = cached[item.path] else { continue }
                entries.append(entry.updating(tail: tailFacts(at: url, size: item.size), item: item))
            case (.full, .gemini):
                if let entry = geminiEntry(at: url, item: item) { entries.append(entry) }
            case (.full, _):
                let head = headFacts(at: url, cap: ClaudeTranscriptDecoder.headCap)
                entries.append(TranscriptIndexEntry(item: item, head: head, tail: tailFacts(at: url, size: item.size)))
            }
        }
        return entries
    }

    @concurrent static func previewTurns(for session: AgentSession, locations: AgentSessionsLocations) async
        -> [SessionTurn]?
    {
        let wide = ClaudeTranscriptDecoder.tailWindowWide
        switch session.source {
        case .claude:
            guard let path = session.transcriptPath,
                let (window, offset) = window(at: URL(filePath: path), length: wide)
            else { return nil }
            return ClaudeTranscriptDecoder.previewTurns(window, startsMidLine: offset > 0, limit: previewLimit)
        case .codex:
            let projected = try? CodexStateReader.historyTurns(
                database: locations.codexHistory, threadID: session.sessionID, limit: previewLimit)
            if let projected, !projected.isEmpty { return projected }
            guard let path = session.transcriptPath,
                let (window, offset) = window(at: URL(filePath: path), length: wide)
            else { return nil }
            return CodexStateReader.rolloutTurns(window, startsMidLine: offset > 0, limit: previewLimit)
        case .gemini:
            guard let path = session.transcriptPath else { return nil }
            let url = URL(filePath: path)
            if url.pathExtension == "json" {
                return legacyGemini(at: url).map { GeminiChatDecoder.legacyTurns($0, limit: previewLimit) }
            }
            guard let (window, offset) = window(at: url, length: wide) else { return nil }
            return GeminiChatDecoder.previewTurns(window, startsMidLine: offset > 0, limit: previewLimit)
        case .openCode:
            return try? OpenCodeStateReader.turns(
                database: locations.openCodeDatabase, sessionID: session.sessionID, limit: previewLimit)
        case .tinycast:
            return nil
        }
    }

    @concurrent static func loadCache(_ url: URL, root: String) async -> TranscriptIndexFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return TranscriptIndexFile.decode(data, projectsRoot: root)
    }

    @concurrent static func saveCache(_ file: TranscriptIndexFile, to url: URL) async {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? file.encoded().write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Codex's or OpenCode's database; a failure is that source's own and never blocks the other.
    @concurrent static func databaseSessions(
        _ source: AgentSource, locations: AgentSessionsLocations, includeArchived: Bool
    ) async -> Result<[AgentSession], HistoryDatabase.Failure> {
        do throws(HistoryDatabase.Failure) {
            switch source {
            case .codex:
                return .success(
                    try CodexStateReader.threads(database: locations.codexState, includeArchived: includeArchived))
            case .openCode:
                return .success(
                    try OpenCodeStateReader.sessions(
                        database: locations.openCodeDatabase, includeArchived: includeArchived))
            case .claude, .gemini, .tinycast:
                return .success([])
            }
        } catch {
            return .failure(error)
        }
    }

    /// The session an event names, from this Mac's own history; never from the URL's text.
    @concurrent static func resolve(_ event: AgentEvent, claudeRoot: URL, codexState: URL, now: Date) async
        -> AgentActivity
    {
        var activity = AgentActivity(agent: event.agent, sessionID: event.sessionID, updatedAt: now)
        switch event.agent {
        case .claude:
            guard let url = claudeTranscript(event.sessionID, root: claudeRoot),
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            else { break }
            let head = headFacts(at: url, cap: eventHeadCap)
            let tail = tailFacts(at: url, size: Int64(size))
            let (title, origin) = ClaudeTranscriptDecoder.title(head: head, tail: tail)
            activity.title = origin == .untitled ? nil : title
            activity.directory = tail.relocatedCwd ?? head.cwd
            activity.host = ClaudeTranscriptDecoder.host(entrypoint: head.entrypoint)
        case .codex:
            guard let thread = try? CodexStateReader.thread(database: codexState, id: event.sessionID) else { break }
            activity.title = thread.titleOrigin == .untitled ? nil : thread.title
            activity.directory = thread.directory
            activity.host = thread.host
        case .gemini, .openCode, .tinycast:
            break
        }
        return activity
    }

    // MARK: - Reads

    static func headFacts(at url: URL, cap: Int) -> ClaudeTranscriptDecoder.HeadFacts {
        var reader = ClaudeTranscriptDecoder.HeadReader()
        readHead(at: url, cap: cap) { reader.consume($0) }
        return reader.finish()
    }

    /// 16 KB chunks until the reader has what it needs or `cap` bytes went by.
    private static func readHead(at url: URL, cap: Int, consume: (Data) -> Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var read = 0
        while read < cap, let data = try? handle.read(upToCount: chunk), !data.isEmpty {
            read += data.count
            if consume(data) { break }
        }
    }

    /// A legacy `.json` is read whole once and cached; past the cap it is left unlisted.
    private static func geminiEntry(at url: URL, item: TranscriptListingItem) -> TranscriptIndexEntry? {
        guard url.pathExtension == "jsonl" else {
            guard let data = legacyGemini(at: url), let (head, tail) = GeminiChatDecoder.legacy(data) else { return nil }
            return TranscriptIndexEntry(item: item, gemini: head, tail: tail)
        }
        var reader = GeminiChatDecoder.HeadReader()
        readHead(at: url, cap: ClaudeTranscriptDecoder.headCap) { reader.consume($0) }
        return TranscriptIndexEntry(item: item, gemini: reader.finish(), tail: geminiTail(at: url))
    }

    /// A reply is written again with its tool results, so the last prompt may sit past the narrow tail.
    private static func geminiTail(at url: URL) -> GeminiChatDecoder.TailFacts {
        guard let (window, offset) = window(at: url, length: ClaudeTranscriptDecoder.tailWindow) else { return .init() }
        let facts = GeminiChatDecoder.tail(window, startsMidLine: offset > 0)
        guard facts.lastPrompt == nil, offset > 0,
            let (wide, wideOffset) = self.window(at: url, length: ClaudeTranscriptDecoder.tailWindowWide)
        else { return facts }
        return GeminiChatDecoder.tail(wide, startsMidLine: wideOffset > 0)
    }

    private static func legacyGemini(at url: URL) -> Data? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max
        return size <= GeminiChatDecoder.legacyCap ? try? Data(contentsOf: url) : nil
    }

    /// The narrow tail first; a wide one only when the narrow held no title at all.
    static func tailFacts(at url: URL, size: Int64) -> ClaudeTranscriptDecoder.TailFacts {
        guard let (window, offset) = window(at: url, length: ClaudeTranscriptDecoder.tailWindow) else {
            return .init()
        }
        let facts = ClaudeTranscriptDecoder.tail(window, startsMidLine: offset > 0)
        guard ClaudeTranscriptDecoder.needsWideTail(facts, fileSize: size),
            let (wide, wideOffset) = self.window(at: url, length: ClaudeTranscriptDecoder.tailWindowWide)
        else { return facts }
        return ClaudeTranscriptDecoder.tail(wide, startsMidLine: wideOffset > 0)
    }

    /// The last `length` bytes and where they start; nil when the file can't be opened.
    static func window(at url: URL, length: Int) -> (Data, UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let offset = end > UInt64(length) ? end - UInt64(length) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: length) else {
            return nil
        }
        return (data, offset)
    }

    // MARK: - Listing

    private static func folders(in root: URL) -> [URL] {
        let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return (folders ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    private static func files(in folder: URL) -> [URL] {
        let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: listingKeys, options: [.skipsHiddenFiles])
        return files ?? []
    }

    private static func item(_ file: URL, path: String) -> TranscriptListingItem? {
        guard let values = try? file.resourceValues(forKeys: Set(listingKeys)), values.isRegularFile == true else {
            return nil
        }
        return TranscriptListingItem(
            path: path, size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    /// The path Gemini writes into a project's folder; an older hash-named folder has none.
    private static func projectRoot(_ project: URL) -> String? {
        let marker = project.appending(path: ".project_root", directoryHint: .notDirectory)
        guard let data = head(of: marker, length: 4_096), let text = String(bytes: data, encoding: .utf8) else {
            return nil
        }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    private static func head(of file: URL, length: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: length)
    }

    /// Read on ⌘O only: the Claude app's record running `transcriptID`, the first that matches.
    @concurrent static func claudeAppSession(transcriptID: String, root: URL) async -> String? {
        guard AgentResumeCommand.isSafeID(transcriptID) else { return nil }
        for organization in folders(in: root).flatMap(folders(in:)) {
            for file in files(in: organization)
            where file.lastPathComponent.hasPrefix(ClaudeAppRoute.recordPrefix) && file.pathExtension == "json" {
                guard !Task.isCancelled else { return nil }
                guard let head = head(of: file, length: ClaudeAppRoute.headLength) else { continue }
                if let id = ClaudeAppRoute.desktopID(inHead: head, transcriptID: transcriptID) { return id }
            }
        }
        return nil
    }

    /// One `fileExists` per project folder; the session id was validated before it got here.
    static func claudeTranscript(_ sessionID: String, root: URL) -> URL? {
        guard AgentResumeCommand.isSafeID(sessionID),
            let projects = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return nil }
        for project in projects {
            let url = root.appending(path: project, directoryHint: .isDirectory)
                .appending(path: sessionID + ".jsonl", directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
