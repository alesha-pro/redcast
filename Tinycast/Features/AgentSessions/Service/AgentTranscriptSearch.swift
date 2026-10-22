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
        query: String, sessions: [AgentSession], codexHistory: URL,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) -> AsyncStream<Hit> {
        let claude = sessions.filter { $0.source == .claude && $0.transcriptPath != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
        let codex = sessions.filter { $0.source == .codex }.sorted { $0.updatedAt > $1.updatedAt }
        let needles = needles(for: query)
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                let total = claude.count + codex.count
                var done = 0
                var hits = 0
                var start = 0
                while start < claude.count, hits < hitLimit, !Task.isCancelled {
                    let pair = Array(claude[start..<min(start + 2, claude.count)])
                    let found = await withTaskGroup(of: (Int, Hit?).self) { group in
                        for (index, session) in pair.enumerated() {
                            group.addTask { (index, searchClaude(session, needles: needles, query: query)) }
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
                for session in codex where hits < hitLimit && !Task.isCancelled {
                    if let text = try? CodexStateReader.historyMatch(
                        database: codexHistory, threadID: session.sessionID, needle: query),
                        let snippet = snippet(in: text, query: query)
                    {
                        hits += 1
                        continuation.yield(Hit(sessionID: session.sessionID, source: .codex, snippet: snippet))
                    }
                    done += 1
                    if done % 8 == 0 || done == total { progress(done, total) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
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

    /// The first conversation line holding the query; tool output never counts as a hit.
    static func searchClaude(_ session: AgentSession, needles: [[UInt8]], query: String) -> Hit? {
        guard let path = session.transcriptPath,
            let data = try? Data(contentsOf: URL(filePath: path), options: .alwaysMapped)
        else { return nil }
        let snippet: String? = data.withUnsafeBytes { buffer in
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
                guard case .conversation(let user) = ClaudeTranscriptDecoder.lineKind(of: line),
                    let object = ClaudeTranscriptDecoder.object(line)
                else { continue }
                for text in texts(in: object, user: user) {
                    if let found = self.snippet(in: text, query: query) { return found }
                }
            }
            return nil
        }
        return snippet.map { Hit(sessionID: session.sessionID, source: .claude, snippet: $0) }
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
