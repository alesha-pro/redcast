import Foundation

/// One provider's WebSocket dialect: what to send and how to read what comes back, with no effects.
protocol LiveVoiceWire: Sendable {
    var request: URLRequest { get }
    /// The PCM16 mono rate the provider hears and the one it speaks at.
    var inputRate: Int { get }
    var outputRate: Int { get }

    func opening(_ setup: LiveVoiceSetup) -> [String]
    func audio(_ pcm: Data) -> String
    func image(_ jpeg: Data, caption: String) -> [String]
    /// What the user typed instead of saying it.
    func typed(_ text: String) -> [String]
    /// A note from the app, never the user's words: a background task's result.
    func note(_ text: String) -> [String]
    /// A call's answer, with the picture it produced placed where this provider will read it first.
    func toolResult(_ result: AIToolResult, for call: AIToolCall, image: Data?, caption: String) -> [String]
    /// Asks for a reply where the provider does not start one on its own.
    func reply() -> [String]
    /// Stops an in-flight reply when the user manually interrupts from the capsule.
    func cancelReply() -> [String]
    /// What the provider must hear after playback was cut `played` milliseconds into `item`.
    func interruption(played milliseconds: Int, of item: String) -> [String]
    /// Mutating, since a provider may report a reply's cost apart from the reply's end.
    mutating func events(from message: Data) -> [LiveVoiceEvent]
}

extension LiveVoiceWire {
    func cancelReply() -> [String] { [] }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        else { return "{}" }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    static func object(_ message: Data) -> [String: JSONValue]? {
        JSONValue(data: message)?.objectValue
    }
}
