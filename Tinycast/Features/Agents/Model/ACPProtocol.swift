import Foundation

/// Agent Client Protocol v1 framing: one JSON-RPC message per line over the agent's stdio.
enum ACPProtocol {
    static let version = 1

    /// The agent numbers its own requests, as an integer or a string; answered in kind.
    enum RequestID: Hashable, Sendable {
        case int(Int)
        case string(String)

        var json: Any {
            switch self {
            case .int(let value): value
            case .string(let value): value
            }
        }
    }

    enum Message: Sendable {
        case response(id: Int, result: JSONValue)
        case failure(id: Int, code: Int, message: String)
        case request(id: RequestID, method: String, params: JSONValue)
        case notification(method: String, params: JSONValue)
        case invalid
    }

    static func parse(_ line: Data) -> Message {
        guard let object = JSONValue(data: line)?.objectValue else { return .invalid }
        let method = object["method"]?.stringValue
        let params = object["params"] ?? .null
        if let method {
            guard let raw = object["id"] else { return .notification(method: method, params: params) }
            if let id = raw.intValue { return .request(id: .int(id), method: method, params: params) }
            if let id = raw.stringValue {
                return .request(id: .string(id), method: method, params: params)
            }
            return .invalid
        }
        guard let id = object["id"]?.intValue else { return .invalid }
        if let error = object["error"]?.objectValue {
            return .failure(
                id: id, code: error["code"]?.intValue ?? 0,
                message: error["message"]?.stringValue ?? "The agent returned an error.")
        }
        return .response(id: id, result: object["result"] ?? .null)
    }

    static func request(id: Int, method: String, params: [String: Any]) -> Data {
        line(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    static func notification(method: String, params: [String: Any]) -> Data {
        line(["jsonrpc": "2.0", "method": method, "params": params])
    }

    static func response(id: RequestID, result: [String: Any]) -> Data {
        line(["jsonrpc": "2.0", "id": id.json, "result": result])
    }

    static func errorResponse(id: RequestID, code: Int, message: String) -> Data {
        line(["jsonrpc": "2.0", "id": id.json, "error": ["code": code, "message": message]])
    }

    /// `JSONSerialization` escapes every newline inside strings, so one message is one line.
    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}

/// One `session/update`, narrowed to what a transcript can show.
enum ACPUpdate: Equatable, Sendable {
    case messageChunk(String)
    case thoughtChunk(String)
    case toolCall(ACPToolCall)
    case toolCallUpdate(ACPToolCall)
    case plan([ACPPlanEntry])
    case usage(used: Int, size: Int, costUSD: Double?)
    /// The agent moved itself to another mode, as Claude Code does when it leaves plan mode.
    case mode(String)
    /// Commands, notices and the rest: known to exist, not drawn yet.
    case other(String)

    static func decode(_ params: JSONValue) -> (sessionID: String, update: ACPUpdate)? {
        guard let object = params.objectValue, let sessionID = object["sessionId"]?.stringValue,
            let update = object["update"]?.objectValue,
            let kind = update["sessionUpdate"]?.stringValue
        else { return nil }
        let decoded: ACPUpdate
        switch kind {
        case "agent_message_chunk":
            decoded = .messageChunk(text(of: update["content"]))
        case "agent_thought_chunk":
            decoded = .thoughtChunk(text(of: update["content"]))
        case "tool_call":
            guard let call = ACPToolCall(update) else { return nil }
            decoded = .toolCall(call)
        case "tool_call_update":
            guard let call = ACPToolCall(update) else { return nil }
            decoded = .toolCallUpdate(call)
        case "plan":
            decoded = .plan((update["entries"]?.arrayValue ?? []).compactMap(ACPPlanEntry.init))
        case "current_mode_update":
            guard let mode = update["currentModeId"]?.stringValue else { return nil }
            decoded = .mode(mode)
        case "usage_update":
            let cost = update["cost"]?.objectValue
            let usd =
                cost?["currency"]?.stringValue?.uppercased() == "USD"
                ? cost?["amount"].flatMap(number) : nil
            decoded = .usage(
                used: update["used"]?.intValue ?? 0, size: update["size"]?.intValue ?? 0,
                costUSD: usd)
        default:
            decoded = .other(kind)
        }
        return (sessionID, decoded)
    }

    /// Text blocks only; an image or a link in a message chunk has no place in a text transcript.
    static func text(of content: JSONValue?) -> String {
        guard let block = content?.objectValue, block["type"]?.stringValue == "text" else { return "" }
        return block["text"]?.stringValue ?? ""
    }

    private static func number(_ value: JSONValue) -> Double? {
        if case .number(let number) = value { return number }
        return nil
    }
}

/// The modes a session offers, from `session/new` or `session/load`, and the one it is in.
struct ACPModes: Equatable, Sendable {
    struct Mode: Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let description: String?
    }

    var current: String?
    let available: [Mode]

    init(current: String?, available: [Mode]) {
        self.current = current
        self.available = available
    }

    init?(result: JSONValue) {
        guard let modes = result.objectValue?["modes"]?.objectValue else { return nil }
        let available: [Mode] = (modes["availableModes"]?.arrayValue ?? []).compactMap { value in
            guard let mode = value.objectValue, let id = mode["id"]?.stringValue else { return nil }
            return Mode(
                id: id, name: mode["name"]?.stringValue ?? id,
                description: mode["description"]?.stringValue)
        }
        guard !available.isEmpty else { return nil }
        self.init(current: modes["currentModeId"]?.stringValue, available: available)
    }

    var currentMode: Mode? { available.first { $0.id == current } }
}

struct ACPDiff: Equatable, Sendable {
    let path: String
    let oldText: String?
    let newText: String
}

/// A tool call as reported or updated; an update carries only what changed.
struct ACPToolCall: Equatable, Sendable {
    enum Status: String, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
        case failed
    }

    let id: String
    var title: String?
    var kind: String?
    var status: Status?
    var rawInput: JSONValue?
    var diffs: [ACPDiff]
    var text: String?

    init?(_ object: [String: JSONValue]) {
        guard let id = object["toolCallId"]?.stringValue else { return nil }
        self.id = id
        title = object["title"]?.stringValue
        kind = object["kind"]?.stringValue
        status = object["status"]?.stringValue.flatMap(Status.init(rawValue:))
        rawInput = object["rawInput"].flatMap { $0 == .null ? nil : $0 }
        var diffs: [ACPDiff] = []
        var texts: [String] = []
        for item in object["content"]?.arrayValue ?? [] {
            guard let item = item.objectValue else { continue }
            switch item["type"]?.stringValue {
            case "diff":
                guard let path = item["path"]?.stringValue,
                    let newText = item["newText"]?.stringValue
                else { continue }
                diffs.append(
                    ACPDiff(path: path, oldText: item["oldText"]?.stringValue, newText: newText))
            case "content":
                let text = ACPUpdate.text(of: item["content"])
                if !text.isEmpty { texts.append(text) }
            default:
                continue
            }
        }
        self.diffs = diffs
        text = texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// What a permission dialog shows under the title: the command, the file, or the diff.
    var summary: String {
        var parts: [String] = []
        if let input = rawInput?.objectValue {
            for key in ["command", "cmd", "path", "file_path", "url", "pattern", "query"] {
                if let value = input[key]?.stringValue {
                    parts.append(value)
                } else if let list = input[key]?.arrayValue {
                    parts.append(list.compactMap(\.stringValue).joined(separator: " "))
                }
            }
        }
        for diff in diffs.prefix(3) {
            let old = diff.oldText.map { "− " + Self.clipped($0) + "\n" } ?? ""
            parts.append(diff.path + "\n" + old + "+ " + Self.clipped(diff.newText))
        }
        if parts.isEmpty, let text { parts.append(Self.clipped(text)) }
        return parts.joined(separator: "\n\n")
    }

    private static func clipped(_ text: String) -> String {
        text.count <= 500 ? text : String(text.prefix(500)) + "…"
    }
}

struct ACPPlanEntry: Equatable, Sendable {
    let content: String
    let status: String

    init?(_ value: JSONValue) {
        guard let object = value.objectValue, let content = object["content"]?.stringValue else {
            return nil
        }
        self.content = content
        status = object["status"]?.stringValue ?? "pending"
    }
}

/// `session/request_permission`: what the agent wants to do, and the answers it offers.
struct ACPPermissionRequest: Sendable {
    struct Option: Equatable, Sendable {
        enum Kind: String, Sendable {
            case allowOnce = "allow_once"
            case allowAlways = "allow_always"
            case rejectOnce = "reject_once"
            case rejectAlways = "reject_always"
        }

        let id: String
        let name: String
        let kind: Kind?

        var allows: Bool { kind == .allowOnce || kind == .allowAlways }
    }

    let sessionID: String
    let toolCall: ACPToolCall
    let options: [Option]

    init?(_ params: JSONValue) {
        guard let object = params.objectValue, let sessionID = object["sessionId"]?.stringValue,
            let call = object["toolCall"]?.objectValue.flatMap(ACPToolCall.init)
        else { return nil }
        self.sessionID = sessionID
        toolCall = call
        options = (object["options"]?.arrayValue ?? []).compactMap { value in
            guard let option = value.objectValue, let id = option["optionId"]?.stringValue else {
                return nil
            }
            return Option(
                id: id, name: option["name"]?.stringValue ?? id,
                kind: option["kind"]?.stringValue.flatMap(Option.Kind.init(rawValue:)))
        }
    }

    /// Allows first; the least committal refusal last, since a dialog's last answer is Cancel.
    var dialogOptions: [Option] {
        let rank: (Option) -> Int = { option in
            switch option.kind {
            case .allowOnce: 0
            case .allowAlways: 1
            case .none: 2
            case .rejectAlways: 3
            case .rejectOnce: 4
            }
        }
        return options.enumerated().sorted { lhs, rhs in
            rank(lhs.element) == rank(rhs.element)
                ? lhs.offset < rhs.offset : rank(lhs.element) < rank(rhs.element)
        }.map(\.element)
    }

    /// Where the dialog keeps its cancel: the last option, when it refuses; nil when every one allows.
    var refusalIndex: Int? {
        let options = dialogOptions
        return options.last?.allows == false ? options.count - 1 : nil
    }

    /// A dialog answer's option; no answer refuses once, or cancels, never leaving an "always".
    func optionID(answering answer: Int?) -> String? {
        let options = dialogOptions
        guard let answer else { return options.first { $0.kind == .rejectOnce }?.id }
        return options.indices.contains(answer) ? options[answer].id : nil
    }

    static func result(selecting optionID: String?) -> [String: Any] {
        guard let optionID else { return ["outcome": ["outcome": "cancelled"]] }
        return ["outcome": ["outcome": "selected", "optionId": optionID]]
    }
}

/// A turn's prompt: the newest user message as content blocks, with context on a fresh session.
enum ACPPrompt {
    struct Capabilities: Equatable, Sendable {
        var image = false
        var embeddedContext = false
    }

    /// Prior turns travel only when the agent could not reload its own copy of the session.
    static let maxHistoryBytes = 24 * 1_024

    static func blocks(
        for message: AIMessage, context: String?, history: [AIMessage], capabilities: Capabilities
    ) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        var preamble: [String] = []
        if let context, !context.isEmpty { preamble.append(context) }
        let earlier = transcript(of: history)
        if !earlier.isEmpty {
            preamble.append("## Earlier in this conversation\n\n" + earlier)
        }
        if !preamble.isEmpty {
            blocks.append(["type": "text", "text": preamble.joined(separator: "\n\n")])
        }
        for document in message.documents {
            blocks.append(block(for: document, capabilities: capabilities))
        }
        if capabilities.image {
            for image in message.images {
                blocks.append([
                    "type": "image", "mimeType": image.mimeType,
                    "data": image.data.base64EncodedString()
                ])
            }
        }
        blocks.append(["type": "text", "text": message.text])
        return blocks
    }

    /// Text files ride as embedded resources when the agent takes them, else inline and fenced.
    private static func block(for document: AIDocument, capabilities: Capabilities) -> [String: Any] {
        let uri = "file:///attachments/" + (document.name.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? "attachment")
        let text = String(data: document.data, encoding: .utf8)
        if capabilities.embeddedContext {
            var resource: [String: Any] = ["uri": uri, "mimeType": document.mimeType]
            if let text {
                resource["text"] = text
            } else {
                resource["blob"] = document.data.base64EncodedString()
            }
            return ["type": "resource", "resource": resource]
        }
        guard let text else {
            return ["type": "text", "text": "[Attachment \(document.name) could not be sent as text.]"]
        }
        return ["type": "text", "text": "Attached file \(document.name):\n````\n\(text)\n````"]
    }

    /// Newest turns win the budget; the cut says so rather than passing for the whole chat.
    static func transcript(of history: [AIMessage]) -> String {
        var turns: [String] = []
        var used = 0
        for message in history.reversed() where message.role == .user || message.role == .assistant {
            let speaker = message.role == .user ? "User" : "Assistant"
            let turn = "\(speaker): \(message.text)"
            // Each turn also costs the blank line that joins it to the next.
            guard used + turn.utf8.count + 2 <= maxHistoryBytes else {
                turns.append("[Earlier turns cut.]")
                break
            }
            turns.append(turn)
            used += turn.utf8.count + 2
        }
        return turns.reversed().joined(separator: "\n\n")
    }
}

/// Turns updates into transcript events, reporting each tool call's end exactly once.
struct ACPEventMapper: Sendable {
    let origin: String
    private var titles: [String: String] = [:]
    private var settled: Set<String> = []
    private var lastPlan: [ACPPlanEntry] = []
    private var lastUsage: (used: Int, size: Int, costUSD: Double?)?

    init(origin: String) {
        self.origin = origin
    }

    mutating func events(for update: ACPUpdate) -> [AIStreamEvent] {
        switch update {
        case .messageChunk(let text):
            return text.isEmpty ? [] : [.text(text)]
        case .thoughtChunk(let text):
            return text.isEmpty ? [] : [.reasoning(text)]
        case .toolCall(let call):
            let title = call.title ?? call.kind ?? "tool"
            titles[call.id] = title
            return [.toolCall(id: call.id, origin: origin, title: title)] + settle(call)
        case .toolCallUpdate(let call):
            var events: [AIStreamEvent] = []
            if titles[call.id] == nil {
                let title = call.title ?? call.kind ?? "tool"
                titles[call.id] = title
                events.append(.toolCall(id: call.id, origin: origin, title: title))
            }
            return events + settle(call)
        case .plan(let entries):
            guard entries != lastPlan, !entries.isEmpty else { return [] }
            lastPlan = entries
            let items = entries.map { entry in
                AgentPlan.Item(
                    step: entry.content, status: AgentPlan.Status(rawValue: entry.status) ?? .pending)
            }
            return [.reasoning(AgentPlan.checklist(items))]
        case .usage(let used, let size, let cost):
            // Held for the turn's end, where the prompt's own result has the finer counts.
            lastUsage = (used, size, cost ?? lastUsage?.costUSD)
            return []
        case .mode, .other:
            return []
        }
    }

    /// Calls still open when the turn ends are settled as failed, so no row spins forever.
    mutating func unsettled() -> [AIStreamEvent] {
        let open = titles.keys.filter { !settled.contains($0) }.sorted()
        settled.formUnion(open)
        return open.map { .toolResult(id: $0, isError: true) }
    }

    /// The turn's end: open calls settled, and one usage from the result and the last window.
    mutating func closing(result: JSONValue) -> [AIStreamEvent] {
        var events = unsettled()
        let counts = result.objectValue?["usage"]?.objectValue
        let window = lastUsage.flatMap { $0.size > 0 ? $0.size : nil }
        if let counts {
            let cached =
                (counts["cachedReadTokens"]?.intValue ?? 0) + (counts["cachedWriteTokens"]?.intValue ?? 0)
            events.append(
                .usage(
                    AIUsage(
                        inputTokens: counts["inputTokens"]?.intValue,
                        outputTokens: counts["outputTokens"]?.intValue,
                        cachedInputTokens: cached > 0 ? cached : nil,
                        reasoningTokens: counts["thoughtTokens"]?.intValue, contextWindow: window,
                        costUSD: lastUsage?.costUSD)))
        } else if let lastUsage, lastUsage.used > 0 {
            events.append(
                .usage(
                    AIUsage(
                        inputTokens: lastUsage.used, outputTokens: 0, contextWindow: window,
                        costUSD: lastUsage.costUSD)))
        }
        return events
    }

    private mutating func settle(_ call: ACPToolCall) -> [AIStreamEvent] {
        guard let status = call.status, status == .completed || status == .failed,
            settled.insert(call.id).inserted
        else { return [] }
        return [.toolResult(id: call.id, isError: status == .failed)]
    }
}
