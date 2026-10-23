import Foundation

/// Which reasoning a request carries back, and where; agent-harness.md cites each rule.
enum AIReasoningReplayPolicy {
    /// The providers whose documented rules differ; every other host is `other`.
    enum Route: Equatable, Sendable {
        case openAI, gemini, openRouter, anthropic
        case deepSeek, qwen, moonshot, miniMax, zai
        case other
    }

    static func route(of configuration: AIHTTPConfiguration) -> Route {
        let host = configuration.route
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if configuration.provider == .gemini || on("generativelanguage.googleapis.com") { return .gemini }
        if configuration.provider == .openRouter || on("openrouter.ai") { return .openRouter }
        if on("api.openai.com") { return .openAI }
        if on("api.anthropic.com") { return .anthropic }
        if on("deepseek.com") { return .deepSeek }
        if on("aliyuncs.com") || on("qianwenai.com") { return .qwen }
        if on("moonshot.ai") || on("moonshot.cn") || on("kimi.com") || on("kimi.ai") { return .moonshot }
        if host.contains("minimax") { return .miniMax }
        if on("z.ai") || on("bigmodel.cn") { return .zai }
        return .other
    }

    /// Body fields that keep earlier turns' reasoning, sent only when the connection says Always.
    static func openAIBody(_ input: AIRequest, configuration: AIHTTPConfiguration) -> [String: Any] {
        guard configuration.reasoningReplay == .always, !configuration.disablesThinking else { return [:] }
        switch route(of: configuration) {
        case .zai: return ["thinking": ["type": "enabled", "clear_thinking": false]]
        case .qwen: return ["preserve_thinking": true]
        default: return [:]
        }
    }

    /// An OpenAI-shaped assistant message with what its route needs of its reasoning.
    static func openAIMessage(
        _ encoded: [String: Any], of message: AIMessage, input: AIRequest,
        configuration: AIHTTPConfiguration
    ) -> [String: Any] {
        guard message.role == .assistant else { return encoded }
        var encoded = encoded
        let route = route(of: configuration)
        let own = message.reasoning.flatMap { isOwn($0, configuration) ? $0 : nil }
        if message.reasoning != nil, own == nil, var calls = encoded["tool_calls"] as? [[String: Any]] {
            for index in calls.indices { calls[index]["extra_content"] = nil }
            encoded["tool_calls"] = calls
        }
        if let own, !configuration.disablesThinking, sends(own, on: route, configuration.reasoningReplay) {
            let form: AIReasoningReplay.Form? = route == .deepSeek ? .reasoningContent : own.form
            switch form {
            case .details?:
                encoded["reasoning_details"] =
                    own.items.isEmpty ? [["type": "reasoning.text", "text": own.text]] : own.items.map(\.jsonObject)
            case .reasoningContent?: encoded["reasoning_content"] = own.text
            case .reasoning?: encoded["reasoning"] = own.text
            case .thinkTags?:
                encoded["content"] = "<think>\(own.text)</think>\n\n" + (encoded["content"] as? String ?? "")
            case .blocks?, nil: break
            }
        }
        // DeepSeek refuses a thinking turn with tools unless every assistant message has the field.
        if route == .deepSeek, !input.tools.isEmpty, !configuration.disablesThinking,
            encoded["reasoning_content"] == nil
        {
            encoded["reasoning_content"] = ""
        }
        return encoded
    }

    /// An Anthropic assistant message of this turn with its thinking blocks back where they streamed.
    static func anthropicContent(
        _ parts: [[String: Any]], of message: AIMessage, configuration: AIHTTPConfiguration
    ) -> [[String: Any]] {
        guard message.role == .assistant, let own = message.reasoning, isOwn(own, configuration),
            own.form == .blocks, !own.isStored, !own.items.isEmpty || !own.layout.isEmpty,
            configuration.reasoningReplay != .never
        else { return parts }
        let blocks = own.items.compactMap { $0.jsonObject as? [String: Any] }
        guard !own.layout.isEmpty else { return blocks + parts }
        // Each text block goes back as it streamed, so the calls and blocks after it keep their prefix.
        let split = own.layout.contains { if case .text = $0 { true } else { false } }
        var rest = split ? parts.filter { $0["type"] as? String != "text" } : parts
        var placed: [[String: Any]] = []
        for slot in own.layout {
            switch slot {
            case .item(let index) where blocks.indices.contains(index): placed.append(blocks[index])
            case .item: continue
            case .text(let said):
                guard !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                placed.append(["type": "text", "text": said])
            case .call(let id):
                guard let at = rest.firstIndex(where: { $0["id"] as? String == id }) else { continue }
                placed.append(rest.remove(at: at))
            }
        }
        return placed + rest
    }

    private static func isOwn(_ reasoning: AIReasoningReplay, _ configuration: AIHTTPConfiguration) -> Bool {
        reasoning.model == configuration.model && reasoning.route == configuration.route
    }

    /// This turn's reasoning goes back wherever the stream gave it; an earlier turn's only where read.
    private static func sends(
        _ reasoning: AIReasoningReplay, on route: Route, _ mode: AIConnection.ReasoningReplay?
    ) -> Bool {
        guard mode != .never, route != .openAI, route != .gemini else { return false }
        guard reasoning.isStored else { return true }
        switch route {
        case .deepSeek, .qwen, .moonshot, .miniMax, .zai: return true
        case .openAI, .gemini, .openRouter, .anthropic, .other: return mode == .always
        }
    }
}
