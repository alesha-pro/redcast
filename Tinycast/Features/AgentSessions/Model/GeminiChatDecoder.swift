import Foundation

/// Reads facts out of Gemini CLI chat files (`chats/session-*.jsonl`); never touches the filesystem.
enum GeminiChatDecoder {
    /// A pre-JSONL `session-*.json` is one object, decoded whole once; past this it is skipped.
    static let legacyCap = 8 * 1_048_576
    static let prefixLength = 512

    struct HeadFacts: Equatable, Sendable {
        var sessionID: String?, createdAt: Date?, firstPrompt: String?, summary: String?
        var isSubagent = false
        var isComplete: Bool { sessionID != nil && firstPrompt != nil }
    }

    struct TailFacts: Equatable, Sendable {
        var summary: String?, lastPrompt: String?
    }

    /// A record by its opening bytes: metadata first, `$set`/`$patch`/`$rewindTo` updates, messages.
    enum LineKind: Equatable, Sendable { case metadata, update, message(user: Bool), other }

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
            let kind = GeminiChatDecoder.lineKind(of: line)
            guard kind != .other, kind != .message(user: false), let record = ClaudeTranscriptDecoder.object(line)
            else { return }
            switch kind {
            case .metadata:
                facts.sessionID = facts.sessionID ?? AgentSessionText.nonEmpty(record["sessionId"])
                let started = (record["startTime"] as? String).flatMap(ClaudeTranscriptDecoder.date)
                facts.createdAt = facts.createdAt ?? started
                facts.isSubagent = facts.isSubagent || record["kind"] as? String == "subagent"
                facts.summary = AgentSessionText.nonEmpty(record["summary"]) ?? facts.summary
            case .update:
                facts.summary = GeminiChatDecoder.summary(in: record) ?? facts.summary
            case .message:
                facts.firstPrompt = facts.firstPrompt ?? GeminiChatDecoder.prompt(in: record)
            case .other:
                break
            }
        }
    }

    static func lineKind(of line: Data) -> LineKind {
        line.prefix(prefixLength).withUnsafeBytes { prefix in
            if starts(prefix, with: "{\"$") { return .update }
            if starts(prefix, with: "{\"id\":") {
                if contains(prefix, "\"type\":\"user\"") { return .message(user: true) }
                if contains(prefix, "\"type\":\"gemini\"") { return .message(user: false) }
                return .other
            }
            return contains(prefix, "\"sessionId\"") ? .metadata : .other
        }
    }

    /// `startsMidLine` drops the first partial line of a window that doesn't begin at offset 0.
    static func tail(_ window: Data, startsMidLine: Bool) -> TailFacts {
        var facts = TailFacts()
        for line in ClaudeTranscriptDecoder.lines(of: window, startsMidLine: startsMidLine).reversed() {
            if facts.summary != nil, facts.lastPrompt != nil { break }
            let kind = lineKind(of: line)
            switch kind {
            case .update, .metadata:
                guard facts.summary == nil, let record = ClaudeTranscriptDecoder.object(line) else { continue }
                facts.summary = kind == .update ? summary(in: record) : AgentSessionText.nonEmpty(record["summary"])
            case .message(user: true):
                guard facts.lastPrompt == nil, let record = ClaudeTranscriptDecoder.object(line) else { continue }
                facts.lastPrompt = prompt(in: record)
            case .message(user: false), .other:
                continue
            }
        }
        return facts
    }

    /// Reply lines carry tool results, so the preview takes lines as long as its whole window.
    static func previewTurns(_ window: Data, startsMidLine: Bool, limit: Int) -> [SessionTurn] {
        var order: [String] = []
        var messages: [String: [String: Any]] = [:]
        for line in ClaudeTranscriptDecoder.lines(of: window, startsMidLine: startsMidLine, cap: window.count) {
            switch lineKind(of: line) {
            case .message:
                guard let record = ClaudeTranscriptDecoder.object(line), let id = record["id"] as? String else {
                    continue
                }
                // A reply is written again as its tool calls and tokens arrive; the last copy stands.
                if messages.updateValue(record, forKey: id) == nil { order.append(id) }
            case .update where line.starts(with: rewindOpening):
                let target = ClaudeTranscriptDecoder.object(line)?["$rewindTo"] as? String
                let cut = target.flatMap(order.firstIndex(of:)) ?? order.startIndex
                for id in order[cut...] { messages[id] = nil }
                order.removeSubrange(cut...)
            case .update, .metadata, .other:
                continue
            }
        }
        return turns(order.compactMap { messages[$0] }, limit: limit)
    }

    /// `/rewind` drops the named message and everything after it; an unknown one drops them all.
    private static let rewindOpening = Array("{\"$rewindTo\":".utf8)

    /// A whole pre-JSONL file, which Gemini never appends to: everything is in one object.
    static func legacy(_ data: Data) -> (head: HeadFacts, tail: TailFacts)? {
        guard let object = ClaudeTranscriptDecoder.object(data), let id = AgentSessionText.nonEmpty(object["sessionId"])
        else { return nil }
        let prompts = (object["messages"] as? [[String: Any]] ?? []).compactMap(prompt(in:))
        var head = HeadFacts(
            sessionID: id, createdAt: (object["startTime"] as? String).flatMap(ClaudeTranscriptDecoder.date),
            firstPrompt: prompts.first, summary: AgentSessionText.nonEmpty(object["summary"]))
        head.isSubagent = object["kind"] as? String == "subagent"
        return (head, TailFacts(summary: head.summary, lastPrompt: prompts.last))
    }

    /// Every prompt and reply of a legacy file, for search inside transcripts.
    static func legacyTexts(_ data: Data) -> [String] {
        (ClaudeTranscriptDecoder.object(data)?["messages"] as? [[String: Any]] ?? []).compactMap { record in
            promptText(in: record) ?? replyText(in: record)
        }
    }

    static func legacyTurns(_ data: Data, limit: Int) -> [SessionTurn] {
        turns(ClaudeTranscriptDecoder.object(data)?["messages"] as? [[String: Any]] ?? [], limit: limit)
    }

    /// What a person typed, one line; nil for tool responses, commands and injected context.
    static func prompt(in record: [String: Any]) -> String? {
        promptText(in: record).map { AgentSessionText.oneLine($0) }
    }

    /// Gemini's own rule for what counts as a resumable prompt.
    static func promptText(in record: [String: Any]) -> String? {
        guard record["type"] as? String == "user",
            let text = texts(record["displayContent"]) ?? texts(record["content"])
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ignoredPrefixes.contains(where: trimmed.hasPrefix) else { return nil }
        return trimmed
    }

    /// A model turn's visible text; thought parts and tool calls are left out.
    static func replyText(in record: [String: Any]) -> String? {
        guard record["type"] as? String == "gemini", let text = texts(record["content"]) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static let ignoredPrefixes = ["/", "?", "<session_context>", "<hook_context>"]

    static func title(head: HeadFacts, tail: TailFacts) -> (String, AgentSessionTitleOrigin) {
        if let summary = tail.summary ?? head.summary {
            return (AgentSessionText.oneLine(summary, limit: AgentSessionText.titleLimit), .generated)
        }
        if let prompt = head.firstPrompt, !prompt.isEmpty {
            return (AgentSessionText.promptTitle(prompt), .prompt)
        }
        return ("", .untitled)
    }

    // MARK: - Records

    private static func summary(in update: [String: Any]) -> String? {
        AgentSessionText.nonEmpty((update["$set"] as? [String: Any])?["summary"])
    }

    /// A `PartListUnion`: a string, one part or a list of them; only plain text parts count.
    private static func texts(_ union: Any?) -> String? {
        if let text = union as? String { return text }
        let parts: [Any] = (union as? [Any]) ?? (union.map { [$0] } ?? [])
        let texts = parts.compactMap { part -> String? in
            if let text = part as? String { return text }
            guard let part = part as? [String: Any], part["thought"] as? Bool != true else { return nil }
            return part["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined()
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
