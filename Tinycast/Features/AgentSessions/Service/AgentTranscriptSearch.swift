import Foundation

/// Search inside transcripts on request: newest first, two files at a time, stops at 50 hits.
enum AgentTranscriptSearch {
    struct Hit: Sendable, Equatable {
        let sessionID: String
        let source: AgentSource
        let snippet: String
    }

    static let hitLimit = 50
    static let minimumQuery = 3
    static let snippetRadius = 80
    private static let decodableLine = 1_048_576
    private static let cancellationStride = 64 * 1_048_576

    /// The stream ends after the last file or the 50th hit; cancelling its consumer stops the scan.
    static func run(
        query: String, sessions: [AgentSession], locations: AgentSessionsLocations,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) -> AsyncStream<Hit> {
        let newest = sessions.sorted { $0.updatedAt > $1.updatedAt }
        let files = newest.filter { [.claude, .gemini].contains($0.source) && $0.transcriptPath != nil }
        let databases = newest.filter { [.codex, .openCode].contains($0.source) }
        let needles = needles(for: query)
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                let total = files.count + databases.count
                var done = 0
                var hits = 0
                var start = 0
                while start < files.count, hits < hitLimit, !Task.isCancelled {
                    let pair = Array(files[start..<min(start + 2, files.count)])
                    let found = await withTaskGroup(of: (Int, Hit?).self) { group in
                        for (index, session) in pair.enumerated() {
                            group.addTask { (index, searchFile(session, needles: needles, query: query)) }
                        }
                        var results: [(Int, Hit?)] = []
                        for await result in group { results.append(result) }
                        return results.sorted { $0.0 < $1.0 }.compactMap(\.1)
                    }
                    for hit in found where hits < hitLimit {
                        hits += 1
                        continuation.yield(hit)
                    }
                    start += pair.count
                    done += pair.count
                    progress(done, total)
                }
                for session in databases where hits < hitLimit && !Task.isCancelled {
                    if let text = databaseMatch(session, query: query, locations: locations),
                        let snippet = snippet(in: text, query: query)
                    {
                        hits += 1
                        continuation.yield(Hit(sessionID: session.sessionID, source: session.source, snippet: snippet))
                    }
                    done += 1
                    if done % 8 == 0 || done == total { progress(done, total) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func databaseMatch(_ session: AgentSession, query: String, locations: AgentSessionsLocations)
        -> String?
    {
        switch session.source {
        case .codex:
            try? CodexStateReader.historyMatch(
                database: locations.codexHistory, threadID: session.sessionID, needle: query)
        case .openCode:
            try? OpenCodeStateReader.match(
                database: locations.openCodeDatabase, sessionID: session.sessionID, needle: query)
        case .claude, .gemini, .tinycast:
            nil
        }
    }

    /// As typed, lowercased and capitalized: JSON keeps non-ASCII raw, so Cyrillic matches too.
    static func needles(for query: String) -> [[UInt8]] {
        let capitalized = query.prefix(1).uppercased() + query.dropFirst()
        var seen: Set<String> = []
        return [query, query.lowercased(), capitalized]
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { Array($0.utf8) }
    }

    static func searchFile(_ session: AgentSession, needles: [[UInt8]], query: String) -> Hit? {
        guard let path = session.transcriptPath else { return nil }
        let snippet: String?
        switch session.source {
        case .claude:
            snippet = search(path, needles: needles, query: query) { line in
                guard case .conversation(let user) = ClaudeTranscriptDecoder.lineKind(of: line),
                    let object = ClaudeTranscriptDecoder.object(line)
                else { return [] }
                return texts(in: object, user: user)
            }
        case .gemini where path.hasSuffix(".json"):
            let data = (try? Data(contentsOf: URL(filePath: path), options: .alwaysMapped)) ?? Data()
            let texts = data.count <= GeminiChatDecoder.legacyCap ? GeminiChatDecoder.legacyTexts(data) : []
            snippet = texts.lazy.compactMap { self.snippet(in: $0, query: query) }.first
        case .gemini:
            snippet = search(path, needles: needles, query: query) { line in
                guard case .message = GeminiChatDecoder.lineKind(of: line),
                    let record = ClaudeTranscriptDecoder.object(line)
                else { return [] }
                return [GeminiChatDecoder.promptText(in: record) ?? GeminiChatDecoder.replyText(in: record)]
                    .compactMap { $0 }
            }
        case .codex, .openCode, .tinycast:
            snippet = nil
        }
        return snippet.map { Hit(sessionID: session.sessionID, source: session.source, snippet: $0) }
    }

    /// The first line whose readable `texts` hold the query, so tool output never counts as a hit.
    private static func search(
        _ path: String, needles: [[UInt8]], query: String, texts: (Data) -> [String]
    ) -> String? {
        guard let data = try? Data(contentsOf: URL(filePath: path), options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { buffer -> String? in
            guard let base = buffer.baseAddress else { return nil }
            var position = 0
            var nextCheck = cancellationStride
            while position < buffer.count {
                if position >= nextCheck {
                    if Task.isCancelled { return nil }
                    nextCheck = position + cancellationStride
                }
                guard let hit = earliest(needles, in: base, from: position, count: buffer.count) else { return nil }
                let lineStart = lineBoundary(before: hit, in: buffer)
                let lineEnd = lineBoundary(after: hit, in: buffer)
                position = lineEnd + 1
                guard lineEnd - lineStart <= decodableLine else { continue }
                let line = Data(bytes: base + lineStart, count: lineEnd - lineStart)
                for text in texts(line) {
                    if let found = self.snippet(in: text, query: query) { return found }
                }
            }
            return nil
        }
    }

    /// ±80 characters around the first case-insensitive match, on one line.
    static func snippet(in text: String, query: String) -> String? {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let lower = text.index(range.lowerBound, offsetBy: -snippetRadius, limitedBy: text.startIndex)
        let upper = text.index(range.upperBound, offsetBy: snippetRadius, limitedBy: text.endIndex)
        let body = AgentSessionText.oneLine(String(text[(lower ?? text.startIndex)..<(upper ?? text.endIndex)]), limit: .max)
        return (lower == nil ? "" : "…") + body + (upper == nil ? "" : "…")
    }

    private static func texts(in object: [String: Any], user: Bool) -> [String] {
        if user { return ClaudeTranscriptDecoder.humanPromptText(in: object).map { [$0] } ?? [] }
        guard let message = object["message"] as? [String: Any] else { return [] }
        if let text = message["content"] as? String { return [text] }
        return (message["content"] as? [[String: Any]] ?? []).compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }
    }

    private static func earliest(
        _ needles: [[UInt8]], in base: UnsafeRawPointer, from position: Int, count: Int
    ) -> Int? {
        var best: Int?
        for needle in needles {
            let limit = (best ?? count) - position
            guard limit >= needle.count else { continue }
            let found = needle.withUnsafeBytes { bytes in
                memmem(base + position, limit, bytes.baseAddress, needle.count)
            }
            if let found { best = base.distance(to: UnsafeRawPointer(found)) }
        }
        return best
    }

    private static func lineBoundary(before offset: Int, in buffer: UnsafeRawBufferPointer) -> Int {
        var index = offset
        while index > 0, buffer[index - 1] != 0x0A { index -= 1 }
        return index
    }

    private static func lineBoundary(after offset: Int, in buffer: UnsafeRawBufferPointer) -> Int {
        guard let base = buffer.baseAddress, let newline = memchr(base + offset, 0x0A, buffer.count - offset)
        else { return buffer.count }
        return base.distance(to: UnsafeRawPointer(newline))
    }
}
