import Foundation

/// OpenAI's Realtime API over WebSocket: the client asks for each reply that a tool or a note needs.
struct OpenAIRealtimeWire: LiveVoiceWire {
    let key: String
    let model: String
    let endpoint: URL?
    let headers: [String: String]
    /// `minimal` answers soonest; `low` is OpenAI's own suggestion once tools are misused.
    var effort = "minimal"

    static let defaultModel = "gpt-realtime-2.1"
    static let defaultVoice = "marin"
    /// The pause that ends a turn. OpenAI's default is 500; shorter answers sooner and cuts in more.
    var silenceMilliseconds = 350
    static let transcriptionModel = "gpt-transcribe"
    static let rate = 24_000

    init(
        key: String, model: String = OpenAIRealtimeWire.defaultModel,
        effort: String = "minimal", endpoint: URL? = nil, headers: [String: String] = [:]
    ) {
        self.key = key
        self.model = model
        self.effort = effort
        self.endpoint = endpoint
        self.headers = headers
    }

    var request: URLRequest {
        let url: URL
        if let endpoint {
            url = endpoint
        } else {
            var components = URLComponents()
            components.scheme = "wss"
            components.host = "api.openai.com"
            components.path = "/v1/realtime"
            components.queryItems = [URLQueryItem(name: "model", value: model)]
            url = components.url ?? URL(fileURLWithPath: "/")
        }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    var inputRate: Int { Self.rate }
    var outputRate: Int { Self.rate }

    func opening(_ setup: LiveVoiceSetup) -> [String] {
        let format: [String: Any] = ["type": "audio/pcm", "rate": Self.rate]
        var transcription: [String: Any] = ["model": Self.transcriptionModel]
        if let language = setup.language { transcription["language"] = language }
        let session: [String: Any] = [
            "type": "realtime",
            "instructions": setup.instructions,
            "output_modalities": ["audio"],
            "audio": [
                "input": [
                    "format": format,
                    "transcription": transcription,
                    "turn_detection": [
                        "type": "server_vad", "silence_duration_ms": silenceMilliseconds,
                        "create_response": true, "interrupt_response": true,
                    ],
                ],
                "output": ["format": format, "voice": setup.voice ?? Self.defaultVoice],
            ],
            "reasoning": ["effort": effort],
            "tools": setup.tools.map { tool in
                [
                    "type": "function", "name": tool.name, "description": tool.description,
                    "parameters": tool.parameters.jsonObject,
                ]
            },
            "tool_choice": "auto",
        ]
        return [Self.json(["type": "session.update", "session": session])]
    }

    func audio(_ pcm: Data) -> String {
        Self.json(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    func image(_ jpeg: Data, caption: String) -> [String] {
        [
            Self.item([
                "type": "message", "role": "user",
                "content": [
                    ["type": "input_text", "text": caption],
                    ["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
                ],
            ])
        ]
    }

    func typed(_ text: String) -> [String] {
        [Self.item(["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]])]
    }

    func note(_ text: String) -> [String] {
        [Self.item(["type": "message", "role": "system", "content": [["type": "input_text", "text": text]]])]
    }

    func toolResult(_ result: AIToolResult, for call: AIToolCall, image: Data?, caption: String) -> [String] {
        let answer = Self.item([
            "type": "function_call_output", "call_id": call.id,
            "output": Self.json([result.isError ? "error" : "result": result.content]),
        ])
        guard let image else { return [answer] }
        return [answer] + self.image(image, caption: caption)
    }

    func reply() -> [String] {
        [Self.json(["type": "response.create"])]
    }

    func cancelReply() -> [String] {
        [Self.json(["type": "response.cancel"])]
    }

    func interruption(played milliseconds: Int, of item: String) -> [String] {
        guard !item.isEmpty else { return [] }
        return [
            Self.json([
                "type": "conversation.item.truncate", "item_id": item, "content_index": 0,
                "audio_end_ms": milliseconds,
            ])
        ]
    }

    func events(from message: Data) -> [LiveVoiceEvent] {
        guard let message = Self.object(message), let type = message["type"]?.stringValue else { return [] }
        switch type {
        case "session.updated":
            return [.ready]
        case "input_audio_buffer.speech_started":
            return [.userStartedSpeaking]
        case "input_audio_buffer.speech_stopped":
            return [.userStoppedSpeaking]
        case "conversation.item.input_audio_transcription.completed":
            guard let heard = message["transcript"]?.stringValue, !heard.isEmpty else { return [] }
            return [.heard(heard)]
        case "response.created":
            return [.replyStarted]
        case "response.output_audio.delta":
            guard let pcm = message["delta"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) else { return [] }
            return [.audio(pcm, item: message["item_id"]?.stringValue ?? "")]
        case "response.output_audio_transcript.delta", "response.output_text.delta":
            guard let said = message["delta"]?.stringValue, !said.isEmpty else { return [] }
            return [.said(said)]
        case "response.output_item.done":
            guard let item = message["item"]?.objectValue, item["type"]?.stringValue == "function_call",
                let name = item["name"]?.stringValue, let id = item["call_id"]?.stringValue
            else { return [] }
            return [.toolCall(AIToolCall(id: id, name: name, arguments: item["arguments"]?.stringValue ?? "{}"))]
        case "response.done":
            return Self.ending(message["response"]?.objectValue ?? [:])
        case "error":
            let detail = message["error"]?.objectValue?["message"]?.stringValue
            return [.failed(detail ?? "OpenAI reported an error.")]
        default:
            return []
        }
    }

    private static func ending(_ response: [String: JSONValue]) -> [LiveVoiceEvent] {
        var events: [LiveVoiceEvent] = []
        if response["status"]?.stringValue == "failed" {
            let detail = response["status_details"]?.objectValue?["error"]?.objectValue?["message"]?.stringValue
            events.append(.failed(detail ?? "OpenAI could not finish the reply."))
        }
        let counted = response["usage"]?.objectValue
        let usage = counted.map {
            LiveVoiceUsage(
                input: $0["input_tokens"]?.intValue ?? 0,
                cached: $0["input_token_details"]?.objectValue?["cached_tokens"]?.intValue ?? 0,
                output: $0["output_tokens"]?.intValue ?? 0)
        }
        return events + [.replyEnded(usage)]
    }

    private static func item(_ item: [String: Any]) -> String {
        json(["type": "conversation.item.create", "item": item])
    }
}
