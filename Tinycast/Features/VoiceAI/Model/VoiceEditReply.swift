import Foundation

/// One spoken edit's reply: the instruction its header names, and the text for the selection.
struct VoiceEditReply: Sendable {
    enum Outcome: Equatable, Sendable {
        case noSpeech
        case edited(String, instruction: String?)
    }

    private var parser = VoiceReplyParser()
    private var instruction: String?
    private var body = ""

    init() {}

    mutating func feed(_ delta: String) {
        parser.feed(delta).forEach { apply($0) }
    }

    /// A reply without the header is the edited text whole.
    mutating func finish(original: String) -> Outcome {
        parser.finish().forEach { apply($0) }
        guard let text = Self.fitted(body, to: original) else { return .noSpeech }
        return .edited(text, instruction: instruction)
    }

    private mutating func apply(_ event: VoiceReplyParser.Event) {
        switch event {
        case .header(_, let question): instruction = question
        case .body(let text): body += text
        }
    }

    /// The selection's own outer whitespace kept; quotes or a fence removed only if it had none.
    static func fitted(_ reply: String, to original: String) -> String? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let core = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleaned = VoiceTranscript.cleaned(trimmed) else { return nil }
        let text = VoiceTranscript.cleaned(core) == core ? cleaned : trimmed
        let leading = original.prefix { $0.isWhitespace }
        let trailing = original.reversed().prefix { $0.isWhitespace }.reversed()
        return String(leading) + text + String(trailing)
    }

    /// Replaced only while the selection is what was edited; line endings may differ.
    static func isSameSelection(_ original: String, _ current: String) -> Bool {
        normalized(original) == normalized(current)
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
