import Foundation

enum VoiceReplyMode: Equatable, Sendable {
    case answer
    case insert
}

/// The reply's two header lines, read as they stream; a reply without them is an answer.
struct VoiceReplyParser: Sendable {
    enum Event: Equatable, Sendable {
        case header(VoiceReplyMode, question: String?)
        case body(String)
    }

    private enum Stage: Equatable {
        case mode
        case question(VoiceReplyMode)
        case leading
        case body
    }

    /// A mode token never runs this long; past it the reply has no header.
    static let tokenLimit = 32
    static let headerLimit = 600
    static let titleLimit = 80

    private static let decorations = CharacterSet(charactersIn: "*#`:").union(.whitespaces)

    private var stage = Stage.mode
    private var buffer = ""
    /// A `\r` that ended a delta may be half of a `\r\n` the next one completes.
    private var pendingReturn = false

    init() {}

    mutating func feed(_ delta: String) -> [Event] {
        var text = (pendingReturn ? "\r" : "") + delta
        pendingReturn = text.unicodeScalars.last == "\r"
        if pendingReturn { text.unicodeScalars.removeLast() }
        return advance(Self.normalized(text), finishing: false)
    }

    mutating func finish() -> [Event] {
        let tail = pendingReturn ? "\n" : ""
        pendingReturn = false
        return advance(tail, finishing: true)
    }

    /// The panel's title: the question on one line, cut to `titleLimit` characters.
    static func title(_ question: String) -> String {
        let line = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > titleLimit else { return line }
        return line.prefix(titleLimit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    private mutating func advance(_ text: String, finishing: Bool) -> [Event] {
        switch stage {
        case .body:
            return text.isEmpty ? [] : [.body(text)]
        case .leading:
            return skipLeadingNewlines(text)
        case .mode, .question:
            buffer += text
            return readHeader(finishing: finishing)
        }
    }

    private mutating func readHeader(finishing: Bool) -> [Event] {
        if stage == .mode {
            trimLeadingBlankLines()
            guard let newline = buffer.firstIndex(of: "\n") else {
                guard finishing || buffer.count > Self.tokenLimit else { return [] }
                if finishing, let mode = Self.mode(buffer) { return header(mode, question: nil, rest: "") }
                return fallback()
            }
            guard let mode = Self.mode(buffer[..<newline]) else { return fallback() }
            buffer = String(buffer[buffer.index(after: newline)...])
            stage = .question(mode)
        }
        guard case .question(let mode) = stage else { return [] }
        trimLeadingBlankLines()
        guard let marker = Self.questionMarkerEnd(in: buffer) else {
            let start = buffer.drop { $0 == " " || $0 == "\t" }
            let undecided = start.isEmpty || start == "Q" || start == "q"
            guard undecided, !finishing else { return header(mode, question: nil, rest: buffer) }
            return []
        }
        guard let newline = buffer.firstIndex(of: "\n") else {
            if finishing { return header(mode, question: Self.question(buffer[marker...]), rest: "") }
            guard buffer.count > Self.headerLimit else { return [] }
            return header(mode, question: nil, rest: buffer)
        }
        let question = Self.question(buffer[marker..<newline])
        return header(mode, question: question, rest: String(buffer[buffer.index(after: newline)...]))
    }

    private mutating func header(_ mode: VoiceReplyMode, question: String?, rest: String) -> [Event] {
        buffer = ""
        stage = .leading
        return [.header(mode, question: question)] + skipLeadingNewlines(rest)
    }

    private mutating func fallback() -> [Event] {
        header(.answer, question: nil, rest: buffer)
    }

    private mutating func skipLeadingNewlines(_ text: String) -> [Event] {
        let body = text.drop { $0 == "\n" }
        guard !body.isEmpty else { return [] }
        stage = .body
        return [.body(String(body))]
    }

    /// The model may open with a blank line before either header line.
    private mutating func trimLeadingBlankLines() {
        while let newline = buffer.firstIndex(of: "\n"),
            buffer[..<newline].allSatisfy(\.isWhitespace)
        {
            buffer.removeSubrange(...newline)
        }
    }

    private static func mode(_ line: some StringProtocol) -> VoiceReplyMode? {
        switch String(line).trimmingCharacters(in: decorations).uppercased() {
        case "ANSWER": .answer
        case "INSERT": .insert
        default: nil
        }
    }

    /// Where the question starts, past `Q:` or the full-width `Q：`; nil when the line has neither.
    private static func questionMarkerEnd(in text: String) -> String.Index? {
        let line = text.drop { $0 == " " || $0 == "\t" }
        guard let first = line.first, first == "Q" || first == "q" else { return nil }
        let colon = line.index(after: line.startIndex)
        guard colon < line.endIndex, line[colon] == ":" || line[colon] == "：" else { return nil }
        return line.index(after: colon)
    }

    private static func question(_ text: Substring) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalized(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

enum VoiceTranscript {
    /// How a model quotes its reply, as the prompt's examples do; «» around it all was dictated.
    private static let replyQuotes: [(open: Character, close: Character)] = [("\"", "\""), ("“", "”")]
    private static let quotePairs = replyQuotes + [("«", "»")]

    /// A dictation's text from inside its tag: fences kept, quotes wrapping all of it taken off.
    static func dictation(_ reply: String) -> String? {
        guard let inside = tagged(reply) else { return cleaned(reply) }
        let text = unquoted(inside.trimmingCharacters(in: .whitespacesAndNewlines), pairs: replyQuotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == VoicePrompt.noSpeech ? nil : text
    }

    /// From the first opening tag to the closing one after it; a cut reply may lack either.
    private static func tagged(_ reply: String) -> Substring? {
        let open = reply.range(of: VoicePrompt.transcriptOpen, options: .caseInsensitive)
        let start = open?.upperBound ?? reply.startIndex
        let close = reply.range(
            of: VoicePrompt.transcriptClose, options: .caseInsensitive, range: start..<reply.endIndex)
        guard open != nil || close != nil else { return nil }
        return reply[start..<(close?.lowerBound ?? reply.endIndex)]
    }

    /// nil for the no-speech sentinel or nothing at all; strips wrapping quotes and code fences.
    static func cleaned(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != VoicePrompt.noSpeech else { return nil }
        text = unquoted(text)
        text = unfenced(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == VoicePrompt.noSpeech ? nil : text
    }

    private static func unquoted(
        _ text: String, pairs: [(open: Character, close: Character)] = quotePairs
    ) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last,
            let pair = pairs.first(where: { $0.open == first && $0.close == last })
        else { return text }
        let inside = text.dropFirst().dropLast()
        guard !inside.contains(pair.open), !inside.contains(pair.close) else { return text }
        return String(inside)
    }

    private static func unfenced(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6,
            let opening = text.firstIndex(of: "\n")
        else { return text }
        let closing = text.index(text.endIndex, offsetBy: -3)
        guard opening < closing else { return text }
        return String(text[text.index(after: opening)..<closing])
    }
}
