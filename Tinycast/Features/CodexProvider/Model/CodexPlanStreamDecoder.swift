import Foundation

/// Responses API server-sent events, as codex-api's `sse/responses.rs` handles them.
struct CodexPlanStreamDecoder: Sendable {
    private struct PartialCall {
        var callID = ""
        var name = ""
        var arguments = ""
    }

    private let model: String
    private var parser = SSEParser()
    private var partial: [String: PartialCall] = [:]
    private var calls: [AIToolCall] = []
    private var reasoningItems: [JSONValue] = []
    private var summary = ""
    private var hasAnswered = false
    private(set) var isTerminal = false
    /// The last `codex.rate_limits` event, for a transport that sends the numbers in the stream.
    private(set) var limits: CodexPlanLimits?
    private let now: @Sendable () -> Date

    init(model: String, now: @escaping @Sendable () -> Date = Date.init) {
        self.model = model
        self.now = now
    }

    enum Failure: Error, Equatable {
        /// Before any answer text, so the request itself may be tried again.
        case failed(CodexPlanFailure.Detail, beforeAnswer: Bool)
    }

    mutating func feed(_ data: Data) throws -> [AIStreamEvent] {
        try decode(parser.feed(data))
    }

    mutating func finish() throws -> [AIStreamEvent] {
        try decode(parser.finish())
    }

    private mutating func decode(_ payloads: [String]) throws -> [AIStreamEvent] {
        var events: [AIStreamEvent] = []
        for payload in payloads where !isTerminal {
            if payload == "[DONE]" { continue }
            guard let event = JSONValue(data: Data(payload.utf8))?.objectValue,
                let type = event["type"]?.stringValue
            else {
                isTerminal = true
                throw AIProviderError.malformedResponse
            }
            events += try handle(type, event)
        }
        return events
    }

    private mutating func handle(_ type: String, _ event: [String: JSONValue]) throws -> [AIStreamEvent] {
        switch type {
        case "response.output_text.delta":
            guard let delta = event["delta"]?.stringValue, !delta.isEmpty else { return [] }
            hasAnswered = true
            return [.text(delta)]
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            guard let delta = event["delta"]?.stringValue, !delta.isEmpty else { return [] }
            summary += delta
            return [.thinking, .reasoning(delta)]
        case "response.reasoning_summary_part.added":
            guard !summary.isEmpty else { return [.thinking] }
            summary += "\n\n"
            return [.thinking, .reasoning("\n\n")]
        case "response.output_item.added":
            guard let item = event["item"]?.objectValue else { return [] }
            if item["type"]?.stringValue == "reasoning" { return [.thinking] }
            if item["type"]?.stringValue == "function_call", let id = item["id"]?.stringValue {
                partial[id] = PartialCall(
                    callID: item["call_id"]?.stringValue ?? "", name: item["name"]?.stringValue ?? "")
                hasAnswered = true
            }
            return []
        case "response.function_call_arguments.delta":
            guard let id = event["item_id"]?.stringValue, let delta = event["delta"]?.stringValue else {
                return []
            }
            partial[id, default: PartialCall()].arguments += delta
            return []
        case "response.output_item.done":
            guard let item = event["item"]?.objectValue else { return [] }
            absorb(item)
            return []
        case "response.completed":
            return finished(event, cut: false)
        case "response.incomplete":
            let reason = event["response"]?.objectValue?["incomplete_details"]?.objectValue?["reason"]
            return finished(event, cut: reason?.stringValue == "max_output_tokens")
        case "response.failed", "error":
            isTerminal = true
            throw Failure.failed(CodexPlanFailure.detail(in: .object(event)), beforeAnswer: !hasAnswered)
        case "codex.rate_limits":
            limits = CodexPlanLimits.parse(event: .object(event), now: now()) ?? limits
            return []
        default:
            return []
        }
    }

    private mutating func absorb(_ item: [String: JSONValue]) {
        switch item["type"]?.stringValue {
        case "function_call":
            let streamed = item["id"]?.stringValue.flatMap { partial.removeValue(forKey: $0) }
            let name = item["name"]?.stringValue ?? streamed?.name ?? ""
            guard !name.isEmpty else { return }
            calls.append(
                AIToolCall(
                    id: item["call_id"]?.stringValue ?? streamed?.callID ?? "", name: name,
                    arguments: item["arguments"]?.stringValue ?? streamed?.arguments ?? ""))
        case "reasoning":
            // Stateless: an item id names nothing the server kept, so it is never sent back.
            var kept = item
            kept["id"] = nil
            kept["status"] = nil
            reasoningItems.append(.object(kept))
        default:
            break
        }
    }

    private mutating func finished(_ event: [String: JSONValue], cut: Bool) -> [AIStreamEvent] {
        isTerminal = true
        var events: [AIStreamEvent] = []
        if let usage = Self.usage(event["response"]?.objectValue?["usage"]) { events.append(.usage(usage)) }
        if cut { events.append(.outputLimit) }
        if !reasoningItems.isEmpty {
            events.append(
                .reasoningReplay(
                    AIReasoningReplay(
                        route: CodexPlanRequestBody.route, model: model, form: nil, text: summary,
                        items: reasoningItems)))
        }
        events += calls.map(AIStreamEvent.toolCallRequested)
        events.append(.finished)
        return events
    }

    /// Cached prompt tokens count outside `inputTokens`, as every other route reports them.
    static func usage(_ value: JSONValue?) -> AIUsage? {
        guard let raw = value?.objectValue else { return nil }
        let input = raw["input_tokens"]?.intValue
        let cached = raw["input_tokens_details"]?.objectValue?["cached_tokens"]?.intValue
        var usage = AIUsage()
        usage.inputTokens = input.map { $0 - min(cached ?? 0, $0) }
        if let cached, cached > 0 { usage.cachedInputTokens = cached }
        usage.outputTokens = raw["output_tokens"]?.intValue
        usage.reasoningTokens = raw["output_tokens_details"]?.objectValue?["reasoning_tokens"]?.intValue
        return usage
    }
}
