import Foundation

/// One reply's reasoning as it streams, kept in the form it came in so it can go back that way.
struct AIReasoningDecoder: Sendable {
    private let route: String
    private let model: String
    private var form: AIReasoningReplay.Form?
    private var text = ""
    private var items: [JSONValue] = []
    private var signed = false
    /// An Anthropic block's stream index, to its place in `items`.
    private var blocks: [Int: Int] = [:]

    init(route: String, model: String) {
        self.route = route
        self.model = model
    }

    /// An OpenAI-shaped delta: the first non-empty field, as pi reads it, and any details.
    mutating func absorb(delta: [String: JSONValue]) {
        for field in [AIReasoningReplay.Form.reasoningContent, .reasoning] {
            guard let piece = delta[field.rawValue]?.stringValue, !piece.isEmpty else { continue }
            if form == nil { form = field }
            text += piece
            break
        }
        for detail in delta["reasoning_details"]?.arrayValue ?? [] where Self.merge(detail, into: &items) {
            form = .details
        }
    }

    /// What the think-tag decoder took out of the answer.
    mutating func absorb(tagged piece: String) {
        if form == nil { form = .thinkTags }
        text += piece
    }

    /// An Anthropic `thinking` or `redacted_thinking` block opening, as the stream gave it.
    mutating func open(block index: Int, _ block: [String: JSONValue]) {
        guard let type = block["type"]?.stringValue, type == "thinking" || type == "redacted_thinking"
        else { return }
        form = .blocks
        blocks[index] = items.count
        items.append(.object(block))
        text += block["thinking"]?.stringValue ?? ""
    }

    mutating func extend(block index: Int, thinking: String?, signature: String?) {
        guard let position = blocks[index], var block = items[position].objectValue else { return }
        if let thinking {
            block["thinking"] = .string((block["thinking"]?.stringValue ?? "") + thinking)
            text += thinking
        }
        if let signature {
            block["signature"] = .string((block["signature"]?.stringValue ?? "") + signature)
        }
        items[position] = .object(block)
    }

    /// A call that carries a thought signature: the reply is stamped even when it shows no text.
    mutating func noteSignedCall() {
        signed = true
    }

    /// The reply's reasoning, once, before its calls; nil when it kept none.
    mutating func flush() -> AIReasoningReplay? {
        guard form != nil || signed else { return nil }
        defer {
            form = nil
            text = ""
            items = []
            signed = false
            blocks = [:]
        }
        let said = text.isEmpty && form == .details ? items.compactMap(Self.text(of:)).joined() : text
        return AIReasoningReplay(route: route, model: model, form: form, text: said, items: items)
    }

    private static func text(of detail: JSONValue) -> String? {
        detail.objectValue?["text"]?.stringValue ?? detail.objectValue?["summary"]?.stringValue
    }

    /// pi's merge: neighbouring text or summary deltas grow one entry; an encrypted one stays whole.
    @discardableResult
    static func merge(_ detail: JSONValue, into details: inout [JSONValue]) -> Bool {
        guard let entry = detail.objectValue, isReasoningDetail(entry),
            let type = entry["type"]?.stringValue
        else { return false }
        let field: String? =
            switch type {
            case "reasoning.text": "text"
            case "reasoning.summary": "summary"
            default: nil
            }
        guard let field, var last = details.last?.objectValue, last["type"]?.stringValue == type,
            let head = last[field]?.stringValue, let tail = entry[field]?.stringValue
        else {
            details.append(detail)
            return true
        }
        last[field] = .string(head + tail)
        for key in ["signature", "id", "format", "index"] where isUnset(last[key]) {
            if let value = entry[key], !isUnset(value) { last[key] = value }
        }
        details[details.count - 1] = .object(last)
        return true
    }

    private static func isUnset(_ value: JSONValue?) -> Bool {
        value == nil || value == .null || value == .string("")
    }

    /// The three shapes OpenRouter documents; anything else is dropped rather than replayed.
    private static func isReasoningDetail(_ entry: [String: JSONValue]) -> Bool {
        let id = entry["id"].map { $0 == .null || $0.stringValue != nil } ?? true
        let format = entry["format"].map { $0.stringValue != nil } ?? true
        let index = entry["index"].map { if case .number = $0 { true } else { false } } ?? true
        guard id, format, index else { return false }
        switch entry["type"]?.stringValue {
        case "reasoning.text": return entry["text"]?.stringValue != nil
        case "reasoning.summary": return entry["summary"]?.stringValue != nil
        case "reasoning.encrypted": return entry["data"]?.stringValue != nil
        default: return false
        }
    }
}
