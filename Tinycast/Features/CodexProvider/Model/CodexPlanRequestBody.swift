import Foundation

/// A Responses API body inside the plan route's rules: stateless, streamed, no sampling fields.
enum CodexPlanRequestBody {
    /// The route that stamps a reply's reasoning, so only this route's model is sent it again.
    static let route = "codex-plan"

    static func make(
        _ input: AIRequest, model: String, effort: String?, reasons: Bool,
        replay: AIConnection.ReasoningReplay?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "store": false,
            "input": items(input, model: model, replay: replay)
        ]
        if let instructions = input.instructions, !instructions.isEmpty {
            body["instructions"] = instructions
        }
        // Only a model the catalog gave levels is a reasoning model; others refuse the field.
        if reasons {
            var reasoning: [String: Any] = ["summary": "auto"]
            if let effort, effort != AIConnection.ReasoningOptions.providerDefault {
                reasoning["effort"] = effort
            }
            body["reasoning"] = reasoning
            body["include"] = ["reasoning.encrypted_content"]
        }
        if let conversation = input.conversationID {
            body["prompt_cache_key"] = conversation.uuidString.lowercased()
        }
        if !input.tools.isEmpty {
            body["tools"] = input.tools.map { tool -> [String: Any] in
                [
                    "type": "function", "name": tool.name, "description": tool.description,
                    "parameters": tool.parameters.jsonObject, "strict": false
                ]
            }
            body["tool_choice"] = input.forbidsCalls ? "none" : "auto"
            body["parallel_tool_calls"] = true
        }
        return body
    }

    static func items(
        _ input: AIRequest, model: String, replay: AIConnection.ReasoningReplay?
    ) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for message in input.messages {
            switch message.role {
            case .system:
                // The route refuses system items; a developer message carries the same weight.
                items.append(Self.message(role: "developer", parts: [inputText(message.text)]))
            case .user:
                var parts: [[String: Any]] = []
                if !message.text.isEmpty { parts.append(inputText(message.text)) }
                parts += message.images.map { ["type": "input_image", "image_url": $0.dataURL] }
                if !parts.isEmpty { items.append(Self.message(role: "user", parts: parts)) }
            case .assistant:
                if let own = message.reasoning, own.route == route, own.model == model, !own.isStored,
                    replay != .never
                {
                    items += own.items.compactMap { $0.jsonObject as? [String: Any] }
                }
                if !message.text.isEmpty {
                    items.append(
                        Self.message(
                            role: "assistant", parts: [["type": "output_text", "text": message.text]]))
                }
                items += message.toolCalls.map { call in
                    [
                        "type": "function_call", "call_id": call.id, "name": call.name,
                        "arguments": call.arguments.isEmpty ? "{}" : call.arguments
                    ]
                }
            case .tool:
                guard let result = message.toolResult else { continue }
                items.append([
                    "type": "function_call_output", "call_id": result.callID, "output": result.content
                ])
            }
        }
        return items
    }

    private static func message(role: String, parts: [[String: Any]]) -> [String: Any] {
        ["type": "message", "role": role, "content": parts]
    }

    private static func inputText(_ text: String) -> [String: Any] {
        ["type": "input_text", "text": text]
    }
}
