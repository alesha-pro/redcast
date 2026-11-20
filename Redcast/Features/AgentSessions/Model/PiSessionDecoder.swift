import Foundation

/// Reads facts out of Pi session files (`<timestamp>_<id>.jsonl`); never touches the filesystem.
enum PiSessionDecoder {
    static let prefixLength = 512

    struct HeadFacts: Equatable, Sendable {
        var sessionID: String?, cwd: String?, createdAt: Date?, firstPrompt: String?, name: String?
        var isComplete: Bool { sessionID != nil && firstPrompt != nil }
    }

    /// `name` is the last `/name` in the window; empty when that one cleared it.
    struct TailFacts: Equatable, Sendable {
        var name: String?, lastPrompt: String?
    }

    enum Role: Equatable, Sendable { case user, assistant, other }

    /// A record by its opening bytes: the header, a `session_info` name, messages.
    enum LineKind: Equatable, Sendable { case header, info, message(Role), other }

    /// Incremental head reader: feed chunks until it answers `true` or the cap is reached.
    struct HeadReader: Sendable {
        private(set) var facts = HeadFacts()
        private var consumed = 0
        private var splitter = JSONLineSplitter(cap: ClaudeTranscriptDecoder.lineCap)

        init() {}

        mutating func consume(_ chunk: Data) -> Bool {
            consumed += chunk.count
            var start = chunk.startIndex
            while let line = splitter.next(in: chunk, from: &start) {
                read(line)
                if facts.isComplete { return true }
            }
            return facts.isComplete || consumed >= ClaudeTranscriptDecoder.headCap
        }

        mutating func finish() -> HeadFacts {
            if let line = splitter.finish() { read(line) }
            return facts
        }

        private mutating func read(_ line: Data) {
            let kind = PiSessionDecoder.lineKind(of: line)
            guard [.header, .info, .message(.user)].contains(kind), let record = ClaudeTranscriptDecoder.object(line)
            else { return }
            switch kind {
            case .header:
                facts.sessionID = facts.sessionID ?? AgentSessionText.nonEmpty(record["id"])
                facts.cwd = facts.cwd ?? AgentSessionText.nonEmpty(record["cwd"])
                let started = (record["timestamp"] as? String).flatMap(ClaudeTranscriptDecoder.date)
                facts.createdAt = facts.createdAt ?? started
            case .info:
                facts.name = PiSessionDecoder.name(in: record) ?? facts.name
            case .message:
                facts.firstPrompt = facts.firstPrompt ?? PiSessionDecoder.prompt(in: record)
            case .other:
                break
            }
        }
    }

    /// Pi writes `type` first and a message's `role` first, so both show in the opening bytes.
    static func lineKind(of line: Data) -> LineKind {
        line.prefix(prefixLength).withUnsafeBytes { prefix in
            if starts(prefix, with: "{\"type\":\"message\"") {
                if contains(prefix, "\"role\":\"user\"") { return .message(.user) }
                return contains(prefix, "\"role\":\"assistant\"") ? .message(.assistant) : .message(.other)
            }
            if starts(prefix, with: "{\"type\":\"session_info\"") { return .info }
            return starts(prefix, with: "{\"type\":\"session\"") ? .header : .other
        }
    }

    /// `startsMidLine` drops the first partial line of a window that doesn't begin at offset 0.
    static func tail(_ window: Data, startsMidLine: Bool) -> TailFacts {
        var facts = TailFacts()
        for line in ClaudeTranscriptDecoder.lines(of: window, startsMidLine: startsMidLine).reversed() {
            if facts.name != nil, facts.lastPrompt != nil { break }
            switch lineKind(of: line) {
            case .info:
                guard facts.name == nil, let record = ClaudeTranscriptDecoder.object(line) else { continue }
                facts.name = name(in: record)
            case .message(.user):
                guard facts.lastPrompt == nil, let record = ClaudeTranscriptDecoder.object(line) else { continue }
                facts.lastPrompt = prompt(in: record)
            case .header, .message, .other:
                continue
            }
        }
        return facts
    }

    /// Entries are a tree, so the preview walks up from the last one and skips abandoned branches.
    static func previewTurns(_ window: Data, startsMidLine: Bool, limit: Int) -> [SessionTurn] {
        var entries: [String: [String: Any]] = [:]
        var leaf: String?
        for line in ClaudeTranscriptDecoder.lines(of: window, startsMidLine: startsMidLine, cap: window.count) {
            guard lineKind(of: line) != .header, let record = ClaudeTranscriptDecoder.object(line),
                let id = record["id"] as? String
            else { continue }
            entries[id] = record
            leaf = id
        }
        var branch: [[String: Any]] = []
        // Taking each entry out as it is visited ends the walk on a parent loop.
        while let id = leaf, let record = entries.removeValue(forKey: id) {
            branch.append(record)
            leaf = record["parentId"] as? String
        }
        return turns(branch.reversed(), limit: limit)
    }

    /// What a person typed, one line; nil for every other entry.
    static func prompt(in record: [String: Any]) -> String? {
        promptText(in: record).map { AgentSessionText.oneLine($0) }
    }

    static func promptText(in record: [String: Any]) -> String? {
        text(in: record, role: "user")
    }

    /// A model turn's visible text; thinking and tool calls are left out.
    static func replyText(in record: [String: Any]) -> String? {
        text(in: record, role: "assistant")
    }

    /// The name `/name` gave wins, else the first prompt; a cleared name is no name.
    static func title(head: HeadFacts, tail: TailFacts) -> (String, AgentSessionTitleOrigin) {
        if let name = tail.name ?? head.name, !name.isEmpty {
            return (AgentSessionText.oneLine(name, limit: AgentSessionText.titleLimit), .named)
        }
        if let prompt = head.firstPrompt, !prompt.isEmpty {
            return (AgentSessionText.promptTitle(prompt), .prompt)
        }
        return ("", .untitled)
    }

    // MARK: - Records

    /// Trimmed, and empty for the entry that clears a name, as Pi's own picker reads it.
    private static func name(in record: [String: Any]) -> String? {
        guard record["type"] as? String == "session_info" else { return nil }
        return (record["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Content is a string or a list of blocks; only `text` blocks count, never images or tools.
    private static func text(in record: [String: Any], role: String) -> String? {
        guard record["type"] as? String == "message", let message = record["message"] as? [String: Any],
            message["role"] as? String == role
        else { return nil }
        let blocks = (message["content"] as? [[String: Any]] ?? []).compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }
        let text = message["content"] as? String ?? blocks.joined(separator: "\n\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Consecutive model turns read as one reply, as a tool-using answer spans several.
    private static func turns(_ records: [[String: Any]], limit: Int) -> [SessionTurn] {
        var turns: [SessionTurn] = []
        var reply: (texts: [String], date: Date?)?
        func closeReply() {
            if let reply, !reply.texts.isEmpty {
                let text = AgentSessionText.bounded(reply.texts.joined(separator: "\n\n"))
                turns.append(SessionTurn(role: .assistant, text: text, date: reply.date))
            }
            reply = nil
        }
        for record in records {
            let date = (record["timestamp"] as? String).flatMap(ClaudeTranscriptDecoder.date)
            if let prompt = promptText(in: record) {
                closeReply()
                turns.append(SessionTurn(role: .user, text: AgentSessionText.bounded(prompt), date: date))
            } else if let text = replyText(in: record) {
                if reply == nil { reply = ([], date) }
                reply?.texts.append(text)
            }
        }
        closeReply()
        return Array(turns.suffix(limit))
    }

    private static func starts(_ buffer: UnsafeRawBufferPointer, with prefix: StaticString) -> Bool {
        buffer.count >= prefix.utf8CodeUnitCount
            && memcmp(buffer.baseAddress, prefix.utf8Start, prefix.utf8CodeUnitCount) == 0
    }

    private static func contains(_ buffer: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        guard let base = buffer.baseAddress, buffer.count >= needle.utf8CodeUnitCount else { return false }
        return memmem(base, buffer.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }
}
