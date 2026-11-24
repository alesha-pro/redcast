import Foundation

/// Google's Live API (`BidiGenerateContent`): JSON over one WebSocket, replies started by the server.
struct GeminiLiveWire: LiveVoiceWire {
    let key: String
    let model: String
    let endpoint: URL?
    let headers: [String: String]
    private var usage: LiveVoiceUsage?

    static let defaultModel = "gemini-3.8-live"
    static let defaultVoice = "Puck"
    /// Google suggests 500 to 800 ms; shorter ends a turn sooner and splits a slow speaker's.
    static let silenceMilliseconds = 500

    static let defaultEndpoint =
        "wss://generativelanguage.googleapis.com/ws/"
        + "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    init(
        key: String, model: String = GeminiLiveWire.defaultModel, endpoint: URL? = nil,
        headers: [String: String] = [:]
    ) {
        self.key = key
        self.model = model
        self.endpoint = endpoint
        self.headers = headers
    }

    var request: URLRequest {
        let url = endpoint ?? URL(string: Self.defaultEndpoint) ?? URL(fileURLWithPath: "/")
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        return request
    }

    let inputRate = 16_000
    let outputRate = 24_000

    func opening(_ setup: LiveVoiceSetup) -> [String] {
        var generation: [String: Any] = ["responseModalities": ["AUDIO"]]
        if let voice = setup.voice {
            generation["speechConfig"] = ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]]
        }
        let resumption: [String: Any] = setup.resumptionHandle.map { ["handle": $0] } ?? [:]
        var body: [String: Any] = [
            "model": "models/\(model)",
            "generationConfig": generation,
            "systemInstruction": ["parts": [["text": setup.instructions]]],
            "realtimeInputConfig": [
                "automaticActivityDetection": ["silenceDurationMs": Self.silenceMilliseconds],
                "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
            ],
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any](),
            "contextWindowCompression": ["slidingWindow": [String: Any]()],
            "sessionResumption": resumption,
        ]
        if !setup.tools.isEmpty {
            body["tools"] = [["functionDeclarations": setup.tools.map(Self.declaration)]]
        }
        return [Self.json(["setup": body])]
    }

    /// Blocking, so the model waits for a screenshot instead of answering without it.
    private static func declaration(_ tool: AITool) -> [String: Any] {
        [
            "name": tool.name, "description": tool.description, "behavior": "BLOCKING",
            "parametersJsonSchema": tool.parameters.jsonObject,
        ]
    }

    func audio(_ pcm: Data) -> String {
        Self.json([
            "realtimeInput": [
                "audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=\(inputRate)"]
            ]
        ])
    }

    /// A caption would count as the user speaking, so the frame travels alone.
    func image(_ jpeg: Data, caption: String) -> [String] {
        [Self.json(["realtimeInput": ["video": ["data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]]])]
    }

    func note(_ text: String) -> [String] {
        typed("[A note from the app, not something the user said]\n\(text)")
    }

    func typed(_ text: String) -> [String] {
        [
            Self.json([
                "clientContent": [
                    "turns": [["role": "user", "parts": [["text": text]]]], "turnComplete": true,
                ]
            ])
        ]
    }

    func toolResult(_ result: AIToolResult, for call: AIToolCall, image: Data?, caption: String) -> [String] {
        let answer = Self.json([
            "toolResponse": [
                "functionResponses": [
                    [
                        "id": call.id, "name": call.name,
                        "response": [result.isError ? "error" : "result": result.content],
                    ]
                ]
            ]
        ])
        guard let image else { return [answer] }
        return self.image(image, caption: caption) + [answer]
    }

    func reply() -> [String] { [] }

    func interruption(played milliseconds: Int, of item: String) -> [String] { [] }

    mutating func events(from message: Data) -> [LiveVoiceEvent] {
        guard let message = Self.object(message) else { return [] }
        var events: [LiveVoiceEvent] = []
        if message["setupComplete"] != nil { events.append(.ready) }
        if let counted = message["usageMetadata"]?.objectValue {
            usage = LiveVoiceUsage(
                input: counted["promptTokenCount"]?.intValue ?? 0,
                cached: counted["cachedContentTokenCount"]?.intValue ?? 0,
                output: counted["responseTokenCount"]?.intValue ?? 0)
        }
        switch message["voiceActivity"]?.objectValue?["type"]?.stringValue {
        case "ACTIVITY_START": events.append(.userStartedSpeaking)
        case "ACTIVITY_END": events.append(.userStoppedSpeaking)
        default: break
        }
        for call in message["toolCall"]?.objectValue?["functionCalls"]?.arrayValue ?? [] {
            guard let call = call.objectValue, let name = call["name"]?.stringValue else { continue }
            events.append(
                .toolCall(
                    AIToolCall(
                        id: call["id"]?.stringValue ?? name, name: name,
                        arguments: Self.json(call["args"]?.jsonObject as? [String: Any] ?? [:]))))
        }
        if let error = message["error"]?.objectValue {
            let detail = error["message"]?.stringValue
            events.append(.failed(detail ?? "Gemini reported an error."))
        }
        if let update = message["sessionResumptionUpdate"]?.objectValue,
            update["resumable"]?.boolValue != false,
            let handle = update["newHandle"]?.stringValue, !handle.isEmpty
        {
            events.append(.resumptionHandle(handle))
        }
        if let cancelled = message["toolCallCancellation"]?.objectValue?["ids"]?.arrayValue?
            .compactMap(\.stringValue), !cancelled.isEmpty
        {
            events.append(.toolCallsCancelled(cancelled))
        }
        if let content = message["serverContent"]?.objectValue { events += self.events(in: content) }
        if let warning = message["goAway"]?.objectValue {
            events.append(.sessionExpiring(warning["timeLeft"]?.stringValue))
        }
        return events
    }

    private mutating func events(in content: [String: JSONValue]) -> [LiveVoiceEvent] {
        var events: [LiveVoiceEvent] = []
        if let heard = content["inputTranscription"]?.objectValue?["text"]?.stringValue, !heard.isEmpty {
            events.append(.heard(heard))
        }
        for part in content["modelTurn"]?.objectValue?["parts"]?.arrayValue ?? [] {
            guard let inline = part.objectValue?["inlineData"]?.objectValue,
                inline["mimeType"]?.stringValue?.hasPrefix("audio/pcm") == true,
                let pcm = inline["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) })
            else { continue }
            events.append(.audio(pcm, item: ""))
        }
        if let said = content["outputTranscription"]?.objectValue?["text"]?.stringValue, !said.isEmpty {
            events.append(.said(said))
        }
        if content["interrupted"]?.boolValue == true { events.append(.interrupted) }
        if content["turnComplete"]?.boolValue == true {
            events.append(.replyEnded(usage))
            usage = nil
        }
        return events
    }
}
