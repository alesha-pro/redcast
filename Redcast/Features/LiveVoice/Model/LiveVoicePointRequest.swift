import Foundation

/// A place in a screenshot as fractions of its width and height, origin top left.
struct LiveVoicePoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

/// One question to a vision model that grounds well: where is this thing in this picture?
enum LiveVoicePointRequest {
    /// Gemini answers points as `[y, x]` out of a thousand, the form it was trained to give.
    private static let scale = 1_000.0

    /// An OpenAI-compatible chat body: the picture, then the target.
    static func body(model: String, jpeg: Data, target: String) -> Data {
        let question = """
            Point to: \(target)
            Answer with JSON only, in the format [{"point": [y, x], "label": "<label>"}], where y and x \
            are normalized to 0-1000. If it is not visible in the picture, answer [].
            """
        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]],
                        ["type": "text", "text": question],
                    ],
                ]
            ],
            "max_tokens": 400,
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// The first point in a chat reply, fenced or bare; nil for `[]`, an error or anything else.
    static func point(in reply: Data) -> LiveVoicePoint? {
        guard let message = JSONValue(data: reply)?.objectValue?["choices"]?.arrayValue?.first?.objectValue?["message"],
            let text = message.objectValue?["content"]?.stringValue,
            let match = text.firstMatch(of: /"point"\s*:\s*\[\s*([0-9.]+)\s*,\s*([0-9.]+)\s*\]/),
            let y = Double(match.1), let x = Double(match.2),
            (0...scale).contains(x), (0...scale).contains(y)
        else { return nil }
        return LiveVoicePoint(x: x / scale, y: y / scale)
    }
}
