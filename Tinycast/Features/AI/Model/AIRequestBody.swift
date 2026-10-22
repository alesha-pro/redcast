import Foundation

/// The JSON body each route expects. Pure on purpose: a wrong shape is a mid-conversation 400.
enum AIRequestBody {
    static func make(
        _ input: AIRequest, configuration: AIHTTPConfiguration
    ) -> [String: Any] {
        switch configuration.shape {
        case .openAICompatible: return cacheMarked(openAI(input, configuration: configuration), configuration)
        case .anthropic: return cacheMarked(anthropic(input, configuration: configuration), configuration)
        }
    }

    // Fork: only Claude must be asked to cache, and only its own API and OpenRouter take the field.
    private static func cacheMarked(
        _ body: [String: Any], _ configuration: AIHTTPConfiguration
    ) -> [String: Any] {
        let mark = ["type": "ephemeral"]
        let own =
            configuration.shape == .anthropic
            && configuration.baseURL.host() == URL(string: AIProviderKind.anthropic.defaultBaseURL)?.host()
        let routed =
            configuration.provider == .openRouter
            && configuration.model.drop(while: { $0 == "~" }).hasPrefix("anthropic/")
        guard own || routed else { return body }
        var body = body
        body["cache_control"] = mark
        guard own else { return body }
        // The prompt and tools also cache apart from the chat, so the agent's next chat reads them.
        if let system = body["system"] {
            body["system"] = [["type": "text", "text": system, "cache_control": mark]]
        }
        if var tools = body["tools"] as? [[String: Any]], let last = tools.indices.last {
            tools[last]["cache_control"] = mark
            body["tools"] = tools
        }
        return body
    }

    private static func openAI(
        _ input: AIRequest, configuration: AIHTTPConfiguration
    ) -> [String: Any] {
        var messages = input.messages.compactMap(openAIMessage)
        if let instructions = input.instructions?.nonEmpty {
            messages.insert(["role": "system", "content": instructions], at: 0)
        }
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": messages,
            "stream": true
        ]
        // Only OpenAI's own API must be asked for usage, and a gateway on its preset may refuse it.
        if configuration.baseURL.host() == URL(string: AIProviderKind.openAI.defaultBaseURL)?.host() {
            body["stream_options"] = ["include_usage": true]
        }
        // OpenRouter's own search layer, so it works for every model it routes.
        if input.webSearch, configuration.provider == .openRouter {
            body["plugins"] = [["id": "web"]]
        }
        if let effort = configuration.effort {
            if configuration.provider == .openRouter {
                body["reasoning"] = ["effort": effort]
            } else if effort != AIConnection.ReasoningOptions.providerDefault,
                effort != AIConnection.ReasoningOptions.noEffort
            {
                body["reasoning_effort"] = effort
            }
        }
        if configuration.disablesThinking {
            body["thinking"] = ["type": "disabled"]
        }
        if !input.tools.isEmpty {
            body["tools"] = input.tools.map {
                [
                    "type": "function",
                    "function": [
                        "name": $0.name, "description": $0.description,
                        "parameters": $0.parameters.jsonObject
                    ]
                ]
            }
        }
        return body
    }

    private static func anthropic(
        _ input: AIRequest, configuration: AIHTTPConfiguration
    ) -> [String: Any] {
        let systemParts =
            ([input.instructions]
            + input.messages.compactMap { $0.role == .system ? $0.text : nil })
            .compactMap { $0?.nonEmpty }
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": anthropicMessages(input.messages),
            "max_tokens": input.maxOutputTokens,
            "stream": true
        ]
        if !systemParts.isEmpty { body["system"] = systemParts.joined(separator: "\n\n") }
        if !input.tools.isEmpty {
            body["tools"] = input.tools.map {
                [
                    "name": $0.name, "description": $0.description,
                    "input_schema": $0.parameters.jsonObject
                ]
            }
        }
        return body
    }

    /// Plain text stays a string; only a message with images takes the content-part array.
    private static func openAIMessage(_ message: AIMessage) -> [String: Any]? {
        if let result = message.toolResult {
            return [
                "role": "tool", "tool_call_id": result.callID, "content": result.content
            ]
        }
        let text = message.text.nonEmpty
        if !message.toolCalls.isEmpty {
            return [
                "role": message.role.rawValue,
                "content": text ?? "",
                "tool_calls": message.toolCalls.map(openAIToolCall)
            ]
        }
        let hasAttachments =
            !message.images.isEmpty || !message.documents.isEmpty || !message.audio.isEmpty
        guard text != nil || hasAttachments else { return nil }
        guard hasAttachments else {
            return ["role": message.role.rawValue, "content": text ?? ""]
        }
        var parts: [[String: Any]] = []
        if let text { parts.append(["type": "text", "text": text]) }
        parts += message.images.map { ["type": "image_url", "image_url": ["url": $0.dataURL]] }
        parts += message.documents.map {
            ["type": "file", "file": ["filename": $0.name, "file_data": $0.dataURL]]
        }
        // Raw base64, not a data URL: the one attachment the wire spells that way.
        parts += message.audio.map {
            [
                "type": "input_audio",
                "input_audio": ["data": $0.data.base64EncodedString(), "format": $0.format]
            ]
        }
        return ["role": message.role.rawValue, "content": parts]
    }

    private static func openAIToolCall(_ call: AIToolCall) -> [String: Any] {
        var encoded: [String: Any] = [
            "id": call.id, "type": "function",
            "function": ["name": call.name, "arguments": call.arguments]
        ]
        if let signature = call.thoughtSignature {
            encoded["extra_content"] = ["google": ["thought_signature": signature]]
        }
        return encoded
    }

    /// Anthropic takes tool results as user content, and a run of them has to arrive as one turn.
    private static func anthropicMessages(_ messages: [AIMessage]) -> [[String: Any]] {
        var encoded: [[String: Any]] = []
        var results: [[String: Any]] = []
        for message in messages {
            if let result = message.toolResult {
                results.append([
                    "type": "tool_result", "tool_use_id": result.callID,
                    "content": result.content, "is_error": result.isError
                ])
                continue
            }
            if !results.isEmpty {
                encoded.append(["role": "user", "content": results])
                results = []
            }
            if let value = anthropicMessage(message) { encoded.append(value) }
        }
        if !results.isEmpty { encoded.append(["role": "user", "content": results]) }
        return encoded
    }

    private static func anthropicMessage(_ message: AIMessage) -> [String: Any]? {
        guard message.role != .system else { return nil }
        let text = message.text.nonEmpty
        if !message.toolCalls.isEmpty {
            var parts: [[String: Any]] = text.map { [["type": "text", "text": $0]] } ?? []
            parts += message.toolCalls.map {
                [
                    "type": "tool_use", "id": $0.id, "name": $0.name,
                    "input": JSONValue(data: Data($0.arguments.utf8))?.jsonObject ?? [:]
                ]
            }
            return ["role": message.role.rawValue, "content": parts]
        }
        let hasAttachments = !message.images.isEmpty || !message.documents.isEmpty
        guard text != nil || hasAttachments else { return nil }
        guard hasAttachments else {
            return ["role": message.role.rawValue, "content": text ?? ""]
        }
        var parts: [[String: Any]] = message.images.map {
            [
                "type": "image",
                "source": [
                    "type": "base64", "media_type": $0.mimeType,
                    "data": $0.data.base64EncodedString()
                ]
            ]
        }
        parts += message.documents.map {
            [
                "type": "document",
                "source": [
                    "type": "base64", "media_type": $0.mimeType,
                    "data": $0.data.base64EncodedString()
                ]
            ]
        }
        // Text stays last: a document block has to precede the instruction that refers to it.
        if let text { parts.append(["type": "text", "text": text]) }
        return ["role": message.role.rawValue, "content": parts]
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
