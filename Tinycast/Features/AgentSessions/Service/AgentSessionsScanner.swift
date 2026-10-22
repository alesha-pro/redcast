import Foundation

/// File listing and bounded reads for agent histories, plus the Claude cache file; all off-main.
enum AgentSessionsScanner {
    static let batchSize = 32
    static let previewLimit = 8
    static let eventHeadCap = 16 * 1_024
    private static let chunk = 16 * 1_024

    @concurrent static func listClaude(root: URL) async -> [ClaudeListingItem] {
        let fileManager = FileManager.default
        guard
            let projects = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var items: [ClaudeListingItem] = []
        for project in projects {
            guard !Task.isCancelled else { return [] }
            guard (try? project.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                let files = try? fileManager.contentsOfDirectory(
                    at: project, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            // Depth two only: a subagent's transcript sits a folder deeper and is not a session.
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
                else { continue }
                items.append(
                    ClaudeListingItem(
                        path: project.lastPathComponent + "/" + file.lastPathComponent,
                        size: Int64(values.fileSize ?? 0),
                        modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        return items
    }

    /// One batch of planned steps; `reuse` steps are the caller's and never reach here.
    @concurrent static func scan(
        _ steps: [(ClaudeListingItem, ClaudeRescanPolicy.Step)], cached: [String: ClaudeIndexEntry], root: URL
    ) async -> [ClaudeIndexEntry] {
        var entries: [ClaudeIndexEntry] = []
        for (item, step) in steps {
            guard !Task.isCancelled else { break }
            let url = root.appending(path: item.path, directoryHint: .notDirectory)
            switch step {
            case .reuse:
                if let entry = cached[item.path] { entries.append(entry) }
            case .tail:
                guard let entry = cached[item.path] else { continue }
                entries.append(entry.updating(tail: tailFacts(at: url, size: item.size), item: item))
            case .full:
                let head = headFacts(at: url, cap: ClaudeTranscriptDecoder.headCap)
                entries.append(ClaudeIndexEntry(item: item, head: head, tail: tailFacts(at: url, size: item.size)))
            }
        }
        return entries
    }

    @concurrent static func previewTurns(for session: AgentSession, codexHistory: URL) async -> [SessionTurn]? {
        let wide = ClaudeTranscriptDecoder.tailWindowWide
        switch session.source {
        case .claude:
            guard let path = session.transcriptPath,
                let (window, offset) = window(at: URL(filePath: path), length: wide)
            else { return nil }
            return ClaudeTranscriptDecoder.previewTurns(window, startsMidLine: offset > 0, limit: previewLimit)
        case .codex:
            let projected = try? CodexStateReader.historyTurns(
                database: codexHistory, threadID: session.sessionID, limit: previewLimit)
            if let projected, !projected.isEmpty { return projected }
            guard let path = session.transcriptPath,
                let (window, offset) = window(at: URL(filePath: path), length: wide)
            else { return nil }
            return CodexStateReader.rolloutTurns(window, startsMidLine: offset > 0, limit: previewLimit)
        case .tinycast:
            return nil
        }
    }

    @concurrent static func loadCache(_ url: URL, root: String) async -> ClaudeIndexFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ClaudeIndexFile.decode(data, projectsRoot: root)
    }

    @concurrent static func saveCache(_ file: ClaudeIndexFile, to url: URL) async {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? file.encoded().write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @concurrent static func codexThreads(database: URL, includeArchived: Bool) async
        -> Result<[AgentSession], CodexStateReader.Failure>
    {
        do throws(CodexStateReader.Failure) {
            return .success(try CodexStateReader.threads(database: database, includeArchived: includeArchived))
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
            activity.isAutomated = ClaudeTranscriptDecoder.host(entrypoint: head.entrypoint) == .automated
        case .codex:
            guard let thread = try? CodexStateReader.thread(database: codexState, id: event.sessionID) else { break }
            activity.title = thread.titleOrigin == .untitled ? nil : thread.title
            activity.directory = thread.directory
            activity.isAutomated = thread.isAutomated
        case .tinycast:
            break
        }
        return activity
    }

    // MARK: - Reads

    static func headFacts(at url: URL, cap: Int) -> ClaudeTranscriptDecoder.HeadFacts {
        var reader = ClaudeTranscriptDecoder.HeadReader()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return reader.finish() }
        defer { try? handle.close() }
        var read = 0
        while read < cap, let data = try? handle.read(upToCount: chunk), !data.isEmpty {
            read += data.count
            if reader.consume(data) { break }
        }
        return reader.finish()
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
