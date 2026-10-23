import Foundation

struct SSEParser: Sendable {
    private var buffer = Data()

    mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var payloads: [String] = []
        while let boundary = nextBoundary() {
            let frame = buffer[..<boundary.lowerBound]
            buffer.removeSubrange(buffer.startIndex..<boundary.upperBound)
            if let payload = Self.payload(in: frame) { payloads.append(payload) }
        }
        return payloads
    }

    mutating func finish() -> [String] {
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll() }
        return Self.payload(in: buffer).map { [$0] } ?? []
    }

    private func nextBoundary() -> Range<Data.Index>? {
        let lf = buffer.range(of: Data([0x0A, 0x0A]))
        let crlf = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))
        switch (lf, crlf) {
        case (let lhs?, let rhs?): return lhs.lowerBound < rhs.lowerBound ? lhs : rhs
        case (let range?, nil), (nil, let range?): return range
        case (nil, nil): return nil
        }
    }

    private static func payload(in frame: some DataProtocol) -> String? {
        let text = String(decoding: frame, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var dataLines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(":") { continue }
            if line == "data" {
                dataLines.append("")
            } else if line.hasPrefix("data:") {
                var value = line.dropFirst(5)
                if value.first == " " { value = value.dropFirst() }
                dataLines.append(String(value))
            }
        }
        return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
    }
}

struct AIStreamDecoder: Sendable {
    /// A call arrives in fragments keyed by index, with its id and name only on the first one.
    private struct PartialToolCall {
        var id = ""
        var name = ""
        var arguments = ""
        var thoughtSignature: String?
    }

    private let shape: AIHTTPConfiguration.APIShape
    /// What a provider's own error text must never show; the decoder is handed it, never reads it.
    private let secrets: [String]
    private var parser = SSEParser()
    private var thinkTags = AIThinkTagDecoder()
    private var usage = AIUsage()
    private var partialToolCalls: [Int: PartialToolCall] = [:]
    private(set) var isTerminal = false
    // Fork: the reply's reasoning, stamped with the route and model that must be sent it again.
    private var reasoning: AIReasoningDecoder
    private var hasAnswered = false

    init(
        shape: AIHTTPConfiguration.APIShape, secrets: [String] = [], model: String = "", route: String = ""
    ) {
        self.shape = shape
        self.secrets = secrets
        reasoning = AIReasoningDecoder(route: route, model: model)
    }

    /// Assembled in index order, so a turn's calls reach the loop as the model listed them.
    private mutating func flushToolCalls() -> [AIStreamEvent] {
        // Fork: the reply's reasoning goes first, so the loop has it for the message its calls go on.
        let replay = reasoning.flush().map { [AIStreamEvent.reasoningReplay($0)] } ?? []
        guard !partialToolCalls.isEmpty else { return replay }
        let calls = partialToolCalls.sorted { $0.key < $1.key }.map(\.value)
        partialToolCalls.removeAll()
        return replay + calls.compactMap { call in
            guard !call.name.isEmpty else { return nil }
            return .toolCallRequested(
                AIToolCall(
                    id: call.id, name: call.name, arguments: call.arguments,
                    thoughtSignature: call.thoughtSignature))
        }
    }

    mutating func feed(_ data: Data) throws -> [AIStreamEvent] {
        try decode(parser.feed(data))
    }

    mutating func finish() throws -> [AIStreamEvent] {
        var events = try decode(parser.finish())
        if shape == .openAICompatible, !isTerminal { events += tagged(thinkTags.finish()) }
        return events
    }

    /// Fork: what the think-tag decoder took out of the answer is the reply's reasoning too.
    private mutating func tagged(_ events: [AIStreamEvent]) -> [AIStreamEvent] {
        for case .reasoning(let piece) in events { reasoning.absorb(tagged: piece) }
        return events
    }

    private mutating func decode(_ payloads: [String]) throws -> [AIStreamEvent] {
        var events: [AIStreamEvent] = []
        for payload in payloads where !isTerminal {
            if payload == "[DONE]" {
                isTerminal = true
                if shape == .openAICompatible { events += tagged(thinkTags.finish()) }
                events.append(contentsOf: flushToolCalls())
                events.append(.finished)
                continue
            }
            switch shape {
            case .openAICompatible:
                events.append(contentsOf: try decodeOpenAI(payload))
            case .anthropic:
                events.append(contentsOf: try decodeAnthropic(payload))
            }
        }
        return events
    }

    private mutating func decodeOpenAI(_ payload: String) throws -> [AIStreamEvent] {
        guard let data = payload.data(using: .utf8),
            let chunk = try? JSONDecoder().decode(OpenAIChunk.self, from: data)
        else {
            isTerminal = true
            throw AIProviderError.malformedResponse
        }

        // OpenRouter reports a mid-stream failure as a 200 payload, so it's an event, not a status.
        if chunk.error?.message != nil {
            isTerminal = true
            let said = AIProviderFailure.providerMessage(in: data)
            let message = said.map { AIProviderFailure.kept($0, secrets: secrets) } ?? Self.stopped
            // Fork: before any answer a busy upstream may pass on a retry; after one, it may not.
            if !hasAnswered,
                let recoverable = AIProviderFailure.recoverable(
                    code: chunk.error?.code, said: chunk.error?.message, message: message)
            {
                throw recoverable
            }
            throw AIProviderError.responseFailed(message)
        }
        var events: [AIStreamEvent] = []
        if let choice = chunk.choices?.first {
            if choice.delta?.content?.isEmpty == false || choice.delta?.toolCalls != nil { hasAnswered = true }
            if let content = choice.delta?.content, !content.isEmpty {
                events += tagged(thinkTags.feed(content))
            } else if let reasoning = choice.delta?.reasoningText {
                events += [.thinking, .reasoning(reasoning)]
            }
            // Fork: kept whole for the replay, in the fields it came in, whatever the fold showed.
            if let delta = choice.delta, delta.reasoningText != nil || delta.reasoningDetails != nil {
                reasoning.absorb(delta: Self.rawDelta(in: data))
            }
            for fragment in choice.delta?.toolCalls ?? [] { absorb(fragment) }
            // Fork: a reply the output cap cut may hold a call cut mid-argument; the loop must know.
            if choice.finishReason == "length" { events.append(.outputLimit) }
            if choice.finishReason == "tool_calls" { events.append(contentsOf: flushToolCalls()) }
        }
        if let reported = chunk.usage {
            // Fork: a cache hit counts outside `inputTokens`, as Anthropic's does, so both shapes add up.
            let hit = reported.promptTokensDetails?.cachedTokens ?? reported.promptCacheHitTokens
            usage.inputTokens = reported.promptTokens.map { $0 - min(hit ?? 0, $0) } ?? usage.inputTokens
            if let hit, hit > 0 { usage.cachedInputTokens = hit }
            usage.outputTokens = reported.completionTokens ?? usage.outputTokens
            usage.reasoningTokens =
                reported.completionTokensDetails?.reasoningTokens ?? usage.reasoningTokens
            usage.costUSD = reported.cost ?? usage.costUSD
            events.append(.usage(usage))
        }
        return events
    }

    /// A fragment's index is the only stable handle; a gateway may omit it when there is one call.
    private mutating func absorb(_ fragment: OpenAIChunk.Choice.Delta.ToolCall) {
        var partial = partialToolCalls[fragment.index ?? 0] ?? PartialToolCall()
        if let id = fragment.id, !id.isEmpty { partial.id = id }
        if let name = fragment.function?.name, !name.isEmpty { partial.name = name }
        partial.arguments += fragment.function?.arguments ?? ""
        if let signature = fragment.extraContent?.google?.thoughtSignature {
            partial.thoughtSignature = signature
            // Fork: a signed call stamps its reply, so another model is never sent the signature.
            reasoning.noteSignedCall()
        }
        partialToolCalls[fragment.index ?? 0] = partial
    }

    private mutating func decodeAnthropic(_ payload: String) throws -> [AIStreamEvent] {
        guard let data = payload.data(using: .utf8),
            let event = try? JSONDecoder().decode(AnthropicEvent.self, from: data)
        else {
            isTerminal = true
            throw AIProviderError.malformedResponse
        }

        switch event.type {
        case "content_block_start":
            // Fork: a thinking block goes back as it came, signature and all, where it stood.
            switch event.contentBlock?.type {
            case "tool_use": reasoning.place(call: event.contentBlock?.id ?? "")
            case "text": reasoning.place(text: event.index ?? 0)
            default:
                let block = JSONValue(data: data)?.objectValue?["content_block"]?.objectValue
                if let block { reasoning.open(block: event.index ?? 0, block) }
            }
            guard event.contentBlock?.type == "tool_use" else { return [] }
            partialToolCalls[event.index ?? 0] = PartialToolCall(
                id: event.contentBlock?.id ?? "", name: event.contentBlock?.name ?? "",
                arguments: "")
            return []
        case "content_block_delta":
            if event.delta?.type == "text_delta", let text = event.delta?.text, !text.isEmpty {
                // Fork: each text block is kept apart too, as Claude's later blocks were signed over it.
                reasoning.extend(text: event.index ?? 0, text)
                return [.text(text)]
            }
            if event.delta?.type == "input_json_delta" {
                partialToolCalls[event.index ?? 0]?.arguments += event.delta?.partialJSON ?? ""
                return []
            }
            // Fork: the signature arrives last; both go back with the block.
            reasoning.extend(
                block: event.index ?? 0, thinking: event.delta?.thinking, signature: event.delta?.signature)
            guard event.delta?.type == "thinking_delta" else { return [] }
            guard let thinking = event.delta?.thinking, !thinking.isEmpty else { return [.thinking] }
            return [.thinking, .reasoning(thinking)]
        case "message_start":
            let reported = event.message?.usage
            // Fork: a cache write is new input billed above it, so only a read counts as cached.
            let written = reported?.cacheCreationInputTokens ?? 0
            usage.inputTokens = reported?.inputTokens.map { $0 + written } ?? usage.inputTokens
            if let read = reported?.cacheReadInputTokens, read > 0 { usage.cachedInputTokens = read }
            return [.usage(usage)]
        case "message_delta":
            usage.outputTokens = event.usage?.outputTokens ?? usage.outputTokens
            // Fork: the cap cut this reply, so a call still open in it may be cut too.
            if event.delta?.stopReason == "max_tokens" { return [.usage(usage), .outputLimit] }
            // The calls are complete here, and `message_stop` may never arrive on a tool turn.
            guard event.delta?.stopReason == "tool_use" else { return [.usage(usage)] }
            return [.usage(usage)] + flushToolCalls()
        case "message_stop":
            isTerminal = true
            return flushToolCalls() + [.finished]
        case "error":
            isTerminal = true
            let message = AIProviderFailure.described(
                Self.anthropicErrorMessage(event.error?.type), said: event.error?.message, secrets: secrets)
            // Fork: Anthropic's busy, rate-limited and server errors may pass on a retry.
            if ["overloaded_error", "rate_limit_error", "api_error"].contains(event.error?.type) {
                throw AIProviderRecoverableError(kind: .transient(retryAfter: nil), message: message)
            }
            throw AIProviderError.responseFailed(message)
        default:
            return []
        }
    }

    private static let stopped = String(localized: "The provider stopped the response with an error.")

    /// Fork: the chunk's own delta, untouched: an encrypted entry must go back byte for byte.
    private static func rawDelta(in data: Data) -> [String: JSONValue] {
        let choice = JSONValue(data: data)?.objectValue?["choices"]?.arrayValue?.first?.objectValue
        return choice?["delta"]?.objectValue ?? [:]
    }

    private static func anthropicErrorMessage(_ type: String?) -> String {
        switch type {
        case "authentication_error": return String(localized: "API key rejected — check it in Settings.")
        case "rate_limit_error": return String(localized: "Rate limit reached — try again later.")
        default: return stopped
        }
    }
}

private struct OpenAIChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ReasoningDetail: Decodable { let text: String? }

            struct ToolCall: Decodable {
                struct Function: Decodable {
                    let name: String?
                    let arguments: String?
                }

                struct ExtraContent: Decodable {
                    struct Google: Decodable {
                        let thoughtSignature: String?

                        enum CodingKeys: String, CodingKey {
                            case thoughtSignature = "thought_signature"
                        }
                    }

                    let google: Google?
                }

                let index: Int?
                let id: String?
                let function: Function?
                let extraContent: ExtraContent?

                enum CodingKeys: String, CodingKey {
                    case index, id, function
                    case extraContent = "extra_content"
                }
            }

            let content: String?
            let reasoning: String?
            let reasoningContent: String?
            let reasoningDetails: [ReasoningDetail]?
            let toolCalls: [ToolCall]?

            /// OpenRouter says `reasoning`, DeepSeek and its copies `reasoning_content`.
            var reasoningText: String? {
                let text =
                    [reasoning, reasoningContent].compactMap { $0 }.first { !$0.isEmpty }
                    ?? reasoningDetails?.compactMap(\.text).joined()
                return text?.isEmpty == false ? text : nil
            }

            enum CodingKeys: String, CodingKey {
                case content, reasoning
                case reasoningContent = "reasoning_content"
                case reasoningDetails = "reasoning_details"
                case toolCalls = "tool_calls"
            }
        }

        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        struct CompletionDetails: Decodable {
            let reasoningTokens: Int?

            enum CodingKeys: String, CodingKey {
                case reasoningTokens = "reasoning_tokens"
            }
        }

        struct PromptDetails: Decodable {
            let cachedTokens: Int?

            enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
            }
        }

        let promptTokens: Int?
        let completionTokens: Int?
        let completionTokensDetails: CompletionDetails?
        /// OpenRouter's own figure; a vendor API sends none.
        let cost: Double?
        let promptTokensDetails: PromptDetails?
        /// DeepSeek's own name for the prompt tokens its cache served.
        let promptCacheHitTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case completionTokensDetails = "completion_tokens_details"
            case cost
            case promptTokensDetails = "prompt_tokens_details"
            case promptCacheHitTokens = "prompt_cache_hit_tokens"
        }
    }

    struct ErrorBody: Decodable {
        let message: String?
        /// Fork: OpenRouter's HTTP-like code; a vendor's string code reads as none.
        let code: Int?

        enum CodingKeys: String, CodingKey { case message, code }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            message = try values.decodeIfPresent(String.self, forKey: .message)
            code = try? values.decodeIfPresent(Int.self, forKey: .code)
        }
    }

    let choices: [Choice]?
    let usage: Usage?
    let error: ErrorBody?
}

private struct AnthropicEvent: Decodable {
    struct Delta: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        let partialJSON: String?
        let stopReason: String?
        // Fork: a thinking block's signature, which goes back with it.
        let signature: String?

        enum CodingKeys: String, CodingKey {
            case type, text, thinking, signature
            case partialJSON = "partial_json"
            case stopReason = "stop_reason"
        }
    }

    struct ContentBlock: Decodable {
        let type: String?
        let id: String?
        let name: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }
    }

    struct Message: Decodable { let usage: Usage? }
    struct ErrorBody: Decodable {
        let type: String?
        let message: String?
    }

    let type: String
    let index: Int?
    let delta: Delta?
    let contentBlock: ContentBlock?
    let usage: Usage?
    let message: Message?
    let error: ErrorBody?

    enum CodingKeys: String, CodingKey {
        case type, index, delta, usage, message, error
        case contentBlock = "content_block"
    }
}
