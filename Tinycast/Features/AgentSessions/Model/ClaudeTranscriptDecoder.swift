import Foundation

/// Reads facts out of Claude Code JSONL bytes; never touches the filesystem.
enum ClaudeTranscriptDecoder {
    static let lineCap = 128 * 1_024
    static let headCap = 512 * 1_024
    static let tailWindow = 64 * 1_024
    static let tailWindowWide = 256 * 1_024
    static let prefixLength = 512

    struct HeadFacts: Codable, Equatable, Sendable {
        var sessionID: String?, cwd: String?, branch: String?, entrypoint: String?
        var createdAt: Date?, firstPrompt: String?
        var customTitle: String?, aiTitle: String?, summary: String?
        var isComplete: Bool { cwd != nil && firstPrompt != nil }
    }

    struct TailFacts: Equatable, Sendable {
        var customTitle: String?, aiTitle: String?, summary: String?
        var lastPrompt: String?, relocatedCwd: String?, lastTimestamp: Date?
        var hasTitle: Bool { customTitle != nil || aiTitle != nil || summary != nil }
    }

    enum LineKind: Equatable, Sendable { case meta(String), conversation(user: Bool), toolOutput, other }

    /// Incremental head reader: feed chunks until it answers `true` or the cap is reached.
    struct HeadReader: Sendable {
        private(set) var facts = HeadFacts()
        private(set) var consumed = 0
        /// The longest line ever held, which the harness pins under `lineCap`.
        private(set) var largestCarry = 0
        private var carry = Data()
        private var skipping = false

        init() {}

        /// True once both facts are known, or once `headCap` bytes went by without them.
        mutating func consume(_ chunk: Data) -> Bool {
            consumed += chunk.count
            var start = chunk.startIndex
            while start < chunk.endIndex {
                guard let newline = chunk[start...].firstIndex(of: 0x0A) else {
                    hold(chunk[start...])
                    break
                }
                if !skipping, carry.count + (newline - start) <= lineCap {
                    carry.append(chunk[start..<newline])
                    largestCarry = max(largestCarry, carry.count)
                    read(carry)
                }
                carry.removeAll(keepingCapacity: true)
                skipping = false
                start = newline + 1
                if facts.isComplete { return true }
            }
            return facts.isComplete || consumed >= headCap
        }

        mutating func finish() -> HeadFacts {
            if !skipping, !carry.isEmpty { read(carry) }
            carry = Data()
            return facts
        }

        private mutating func hold(_ part: Data) {
            guard !skipping else { return }
            guard carry.count + part.count <= lineCap else {
                carry.removeAll(keepingCapacity: false)
                skipping = true
                return
            }
            carry.append(part)
            largestCarry = max(largestCarry, carry.count)
        }

        private mutating func read(_ line: Data) {
            let kind = ClaudeTranscriptDecoder.lineKind(of: line)
            switch kind {
            case .meta(let type):
                guard ClaudeTranscriptDecoder.titleTypes.contains(type),
                    let object = ClaudeTranscriptDecoder.object(line)
                else { return }
                facts.sessionID = facts.sessionID ?? object["sessionId"] as? String
                switch type {
                case "custom-title": facts.customTitle = nonEmpty(object["customTitle"]) ?? facts.customTitle
                case "ai-title": facts.aiTitle = nonEmpty(object["aiTitle"]) ?? facts.aiTitle
                case "summary": facts.summary = nonEmpty(object["summary"]) ?? facts.summary
                default: break
                }
            case .conversation(let user):
                guard let object = ClaudeTranscriptDecoder.object(line) else { return }
                if facts.cwd == nil, let cwd = nonEmpty(object["cwd"]) {
                    facts.cwd = cwd
                    facts.sessionID = facts.sessionID ?? object["sessionId"] as? String
                    facts.branch = nonEmpty(object["gitBranch"])
                    facts.entrypoint = nonEmpty(object["entrypoint"])
                    facts.createdAt = (object["timestamp"] as? String).flatMap(ClaudeTranscriptDecoder.date)
                }
                if user, facts.firstPrompt == nil {
                    facts.firstPrompt = ClaudeTranscriptDecoder.humanPrompt(in: object)
                }
            case .toolOutput, .other:
                break
            }
        }
    }

    static let titleTypes: Set<String> = ["custom-title", "ai-title", "summary", "relocated"]

    /// Cheap pre-decode test on a line's first 512 bytes (§6.4).
    static func lineKind(prefix: UnsafeRawBufferPointer) -> LineKind {
        if starts(prefix, with: metaOpening) {
            let valueStart = metaOpening.count
            guard let end = prefix[valueStart...].firstIndex(of: UInt8(ascii: "\"")),
                let type = String(bytes: prefix[valueStart..<end], encoding: .utf8)
            else { return .other }
            return .meta(type)
        }
        if contains(prefix, "\"type\":\"user\"") || contains(prefix, "\"role\":\"user\"") {
            let isTool = contains(prefix, "\"tool_use_id\"") || contains(prefix, "\"type\":\"tool_result\"")
            return isTool ? .toolOutput : .conversation(user: true)
        }
        // An assistant line names its role inside `message`; its own `type` comes kilobytes later.
        if contains(prefix, "\"type\":\"assistant\"") || contains(prefix, "\"role\":\"assistant\"") {
            return .conversation(user: false)
        }
        return .other
    }

    static func lineKind(of line: Data) -> LineKind {
        line.prefix(prefixLength).withUnsafeBytes { lineKind(prefix: $0) }
    }

    /// `startsMidLine` drops the first partial line of a window that doesn't begin at offset 0.
    static func tail(_ window: Data, startsMidLine: Bool) -> TailFacts {
        var facts = TailFacts()
        var lastPrompt: String?
        var lastHuman: String?
        for line in lines(of: window, startsMidLine: startsMidLine).reversed() {
            switch lineKind(of: line) {
            case .meta(let type):
                guard type == "last-prompt" || titleTypes.contains(type), let object = object(line) else {
                    continue
                }
                switch type {
                case "custom-title": facts.customTitle = facts.customTitle ?? nonEmpty(object["customTitle"])
                case "ai-title": facts.aiTitle = facts.aiTitle ?? nonEmpty(object["aiTitle"])
                case "summary": facts.summary = facts.summary ?? nonEmpty(object["summary"])
                case "relocated": facts.relocatedCwd = facts.relocatedCwd ?? nonEmpty(object["relocatedCwd"])
                case "last-prompt":
                    lastPrompt = lastPrompt ?? nonEmpty(object["lastPrompt"]).map { AgentSessionText.oneLine($0) }
                default: break
                }
            case .conversation(user: true):
                guard lastHuman == nil, let object = object(line) else { continue }
                lastHuman = humanPrompt(in: object)
                if lastHuman != nil {
                    facts.lastTimestamp = (object["timestamp"] as? String).flatMap(date)
                }
            case .conversation(user: false), .toolOutput, .other:
                continue
            }
        }
        facts.lastPrompt = lastPrompt ?? lastHuman
        return facts
    }

    /// The scanner reads a wider tail once when the narrow one held no title of any kind.
    static func needsWideTail(_ facts: TailFacts, fileSize: Int64) -> Bool {
        !facts.hasTitle && fileSize > Int64(tailWindow)
    }

    static func previewTurns(_ window: Data, startsMidLine: Bool, limit: Int) -> [SessionTurn] {
        var turns: [SessionTurn] = []
        var reply: (texts: [String], date: Date?)?
        func closeReply() {
            if let reply, !reply.texts.isEmpty {
                let text = AgentSessionText.bounded(reply.texts.joined(separator: "\n\n"))
                turns.append(SessionTurn(role: .assistant, text: text, date: reply.date))
            }
            reply = nil
        }
        for line in lines(of: window, startsMidLine: startsMidLine) {
            guard case .conversation(let user) = lineKind(of: line), let object = object(line) else {
                continue
            }
            let date = (object["timestamp"] as? String).flatMap(Self.date)
            if user {
                guard let text = humanPromptText(in: object) else { continue }
                closeReply()
                turns.append(SessionTurn(role: .user, text: AgentSessionText.bounded(text), date: date))
            } else if object["isSidechain"] as? Bool != true {
                let texts = assistantTexts(in: object)
                guard !texts.isEmpty else { continue }
                if reply == nil { reply = ([], date) }
                reply?.texts += texts
            }
        }
        closeReply()
        return Array(turns.suffix(limit))
    }

    /// The prompt a person typed on this line, or nil for tool output, meta and notifications.
    static func humanPrompt(in line: [String: Any]) -> String? {
        humanPromptText(in: line).map { AgentSessionText.oneLine($0) }
    }

    static func humanPromptText(in line: [String: Any]) -> String? {
        if let type = line["type"] as? String, type != "user" { return nil }
        let flags = ["isMeta", "isCompactSummary", "isVisibleInTranscriptOnly", "isSidechain"]
        guard !flags.contains(where: { line[$0] as? Bool == true }) else { return nil }
        if let kind = (line["origin"] as? [String: Any])?["kind"] as? String, kind != "human" { return nil }
        guard line["toolUseResult"] == nil, let message = line["message"] as? [String: Any] else {
            return nil
        }
        let text: String?
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" || $0["tool_use_id"] != nil })
            else { return nil }
            text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        } else {
            text = nil
        }
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !machinePrefixes.contains(where: trimmed.hasPrefix) else { return nil }
        return trimmed
    }

    /// Text a client or a hook put in the user's turn, never something the person typed.
    static let machinePrefixes = [
        "<command-name>", "<command-message>", "<command-args>", "<local-command-stdout>",
        "<local-command-stderr>", "<local-command-caveat>", "<bash-input>", "<bash-stdout>",
        "<bash-stderr>", "<system-reminder>", "<task-notification>", "Caveat:", "[Request interrupted"
    ]

    static func title(head: HeadFacts, tail: TailFacts) -> (String, AgentSessionTitleOrigin) {
        if let named = tail.customTitle ?? head.customTitle {
            return (AgentSessionText.oneLine(named, limit: AgentSessionText.titleLimit), .named)
        }
        if let generated = tail.aiTitle ?? head.aiTitle ?? tail.summary ?? head.summary {
            return (AgentSessionText.oneLine(generated, limit: AgentSessionText.titleLimit), .generated)
        }
        if let prompt = head.firstPrompt, !prompt.isEmpty {
            return (AgentSessionText.promptTitle(prompt), .prompt)
        }
        return ("", .untitled)
    }

    static func host(entrypoint: String?) -> AgentSessionHost {
        guard let entrypoint else { return .terminal }
        if entrypoint == "claude-desktop" { return .claudeApp }
        if entrypoint.hasPrefix("sdk") { return .automated }
        if entrypoint.contains("vscode") || entrypoint.contains("jetbrains") || entrypoint.contains("ide") {
            return .editor
        }
        return .terminal
    }

    static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    // MARK: - Lines

    private static let metaOpening = Array("{\"type\":\"".utf8)

    /// Lines of a window; one longer than `lineCap` is dropped rather than decoded.
    static func lines(of window: Data, startsMidLine: Bool) -> [Data] {
        var result: [Data] = []
        var start = window.startIndex
        if startsMidLine {
            guard let first = window.firstIndex(of: 0x0A) else { return [] }
            start = first + 1
        }
        while start < window.endIndex {
            let end = window[start...].firstIndex(of: 0x0A) ?? window.endIndex
            if end > start, end - start <= lineCap { result.append(window[start..<end]) }
            start = end + 1
        }
        return result
    }

    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    private static func assistantTexts(in line: [String: Any]) -> [String] {
        guard let message = line["message"] as? [String: Any] else { return [] }
        if let text = message["content"] as? String { return text.isEmpty ? [] : [text] }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { block in
            guard block["type"] as? String == "text", let text = block["text"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func starts(_ buffer: UnsafeRawBufferPointer, with prefix: [UInt8]) -> Bool {
        buffer.count >= prefix.count && zip(buffer, prefix).allSatisfy { $0 == $1 }
    }

    private static func contains(_ buffer: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        guard let base = buffer.baseAddress, buffer.count >= needle.utf8CodeUnitCount else { return false }
        return memmem(base, buffer.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }
}

private func nonEmpty(_ value: Any?) -> String? {
    guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return text
}
