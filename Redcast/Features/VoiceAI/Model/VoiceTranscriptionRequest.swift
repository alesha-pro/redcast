import Foundation

/// A transcription-only model's request to `/audio/transcriptions`, as multipart form data.
struct VoiceTranscriptionRequest: Equatable, Sendable {
    let model: String
    let audio: AIAudio
    var prompt: String?
    var keywords: [String] = []
    /// ISO 639-1 codes; the endpoint refuses an empty list, so none sends no field.
    var languages: [String] = []

    static func make(model: String, audio: AIAudio, options: VoicePrompt.DictationOptions) -> Self {
        VoiceTranscriptionRequest(
            model: model, audio: audio, prompt: options.context.map(prompt(for:)),
            keywords: VoicePrompt.vocabularyWords(options.vocabulary).map(keyword),
            languages: options.languages.compactMap { DictationLanguage(rawValue: $0)?.code }
                .filter { $0.count == 2 })
    }

    /// Plain context, since the model only listens; a screenshot is never sent here.
    static func prompt(for context: VoiceAppContext) -> String {
        guard let title = context.windowTitle else { return "Dictated into \(context.appName)." }
        return "Dictated into \(context.appName), window \"\(title)\"."
    }

    /// The endpoint refuses the whole request over one keyword with an angle bracket.
    private static func keyword(_ word: String) -> String {
        word.filter { $0 != "<" && $0 != ">" }
    }

    var contentType: String { "multipart/form-data; boundary=\(Self.boundary)" }

    func body() -> Data {
        var fields = [("model", model), ("response_format", "json")]
        if let prompt { fields.append(("prompt", prompt)) }
        fields += keywords.filter { !$0.isEmpty }.map { ("keywords[]", $0) }
        fields += languages.map { ("languages[]", $0) }
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(Self.boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let file = "Content-Disposition: form-data; name=\"file\"; filename=\"recording.\(audio.format)\""
        body.append(Data("--\(Self.boundary)\r\n\(file)\r\nContent-Type: audio/\(audio.format)\r\n\r\n".utf8))
        body.append(audio.data)
        body.append(Data("\r\n--\(Self.boundary)--\r\n".utf8))
        return body
    }

    /// Long and random enough never to occur in a recording or a keyword.
    private static let boundary = "redcast-transcription-7f3c9a1e5b2d4086"

    struct Response: Equatable, Sendable {
        /// nil when nothing intelligible was heard.
        let text: String?
        let usage: AIUsage?
    }

    /// The `json` reply's text, and its usage where counted in tokens; seconds have no rate.
    static func response(_ data: Data) throws -> Response {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = object["text"] as? String
        else { throw AIProviderError.malformedResponse }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var usage: AIUsage?
        if let reported = object["usage"] as? [String: Any], reported["type"] as? String == "tokens" {
            usage = AIUsage(
                inputTokens: reported["input_tokens"] as? Int, outputTokens: reported["output_tokens"] as? Int)
        }
        return Response(text: text.isEmpty ? nil : text, usage: usage)
    }
}
