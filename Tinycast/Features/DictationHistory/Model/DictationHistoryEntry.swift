import Foundation

/// One voice input as Dictation History keeps it: its words and where they went, or why it failed.
struct DictationHistoryEntry: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case dictation
        case ask
        case edit

        /// An answer or an edited selection holds more than speech, so it is kept only on request.
        func isKept(voiceReplies: Bool) -> Bool { self == .dictation || voiceReplies }
    }

    enum Engine: String, Sendable {
        case onDevice = "on-device"
        case cloud
    }

    /// A five-minute dictation is a few thousand characters; longer text keeps its head.
    static let maxTextLength = 20_000
    static let maxFailureLength = 120

    let id: UUID
    /// Whole seconds, as the line stores it.
    let date: Date
    let kind: Kind
    /// What was typed, or what an Ask or an edit produced.
    let text: String
    /// What was said when it is not `text`: a mode's input, a question, an edit's instruction.
    let transcript: String?
    let mode: String?
    /// The mode a failed cloud dictation used, so a retry rewrites it the same way.
    let modeID: UUID?
    let engine: Engine?
    let model: String?
    let appName: String?
    let bundleID: String?
    let duration: TimeInterval?
    /// Why the transcription failed, on one line; such an entry has no text until a retry lands.
    let failure: String?

    init(
        id: UUID = UUID(), date: Date, kind: Kind, text: String, transcript: String? = nil,
        mode: String? = nil, modeID: UUID? = nil, engine: Engine? = nil, model: String? = nil,
        appName: String? = nil, bundleID: String? = nil, duration: TimeInterval? = nil,
        failure: String? = nil
    ) {
        self.id = id
        self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        self.kind = kind
        self.text = String(text.prefix(Self.maxTextLength))
        let spoken = transcript.map { String($0.prefix(Self.maxTextLength)) }
        self.transcript = spoken?.isEmpty == false && spoken != self.text ? spoken : nil
        self.mode = mode
        self.modeID = modeID
        self.engine = engine
        self.model = model
        self.appName = appName
        self.bundleID = bundleID
        self.duration = duration
        self.failure = failure.map(Self.failureLine)
    }

    var isFailed: Bool { failure != nil }

    /// An error's first line, its whitespace folded and its length capped, never empty.
    static func failureLine(_ description: String) -> String {
        let line = description.split(whereSeparator: \.isNewline).first.map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        guard let line, !line.isEmpty else { return "?" }
        return line.count <= maxFailureLength ? line : String(line.prefix(maxFailureLength - 1)) + "…"
    }

    /// The same recording heard at last: a normal entry from now on, at its first date and place.
    func transcribed(_ heard: DictationRetryTranscript) -> Self {
        Self(
            id: id, date: date, kind: kind, text: heard.text, transcript: heard.transcript, mode: heard.mode,
            engine: heard.engine, model: heard.model, appName: appName, bundleID: bundleID,
            duration: duration)
    }

    /// Still failed, now for `reason`, on what the retry tried.
    func failed(_ reason: String, on attempt: DictationRetryAttempt) -> Self {
        Self(
            id: id, date: date, kind: kind, text: "", mode: attempt.mode, modeID: attempt.modeID,
            engine: attempt.engine, model: attempt.model, appName: appName, bundleID: bundleID,
            duration: duration, failure: reason)
    }

    // MARK: - Line format

    /// Every field but the date; a later build's extra keys are ignored, a missing one is nil.
    private struct Payload: Codable {
        var id: UUID
        var kind: String?
        var text: String
        var transcript: String?
        var mode: String?
        var modeID: UUID?
        var engine: String?
        var model: String?
        var app: String?
        var bundleID: String?
        var duration: Double?
        var failure: String?
    }

    /// The date's seconds, a tab, then JSON, which escapes every newline the text holds.
    var line: String {
        let payload = Payload(
            id: id, kind: kind.rawValue, text: text, transcript: transcript, mode: mode, modeID: modeID,
            engine: engine?.rawValue, model: model, app: appName, bundleID: bundleID, duration: duration,
            failure: failure)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return String(Int64(date.timeIntervalSince1970)) + "\t" + json + "\n"
    }

    /// An unknown kind reads as a dictation and an unknown engine as none, so no line is hidden.
    init?(line: Data.SubSequence) {
        guard let date = Self.date(of: line), let tab = line.firstIndex(of: Self.tab),
            let payload = try? JSONDecoder().decode(Payload.self, from: Data(line[line.index(after: tab)...]))
        else { return nil }
        self.init(
            id: payload.id, date: date, kind: payload.kind.flatMap(Kind.init(rawValue:)) ?? .dictation,
            text: payload.text, transcript: payload.transcript, mode: payload.mode, modeID: payload.modeID,
            engine: payload.engine.flatMap(Engine.init(rawValue:)), model: payload.model,
            appName: payload.app, bundleID: payload.bundleID,
            duration: payload.duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            failure: payload.failure.flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: - The file

    /// Readable lines from `cutoff` on, oldest first, as the file holds them.
    static func entries(in data: Data, since cutoff: Date? = nil) -> [DictationHistoryEntry] {
        var found: [DictationHistoryEntry] = []
        forEachLine(in: data) { line in
            guard let date = date(of: line), cutoff.map({ date >= $0 }) ?? true,
                let entry = DictationHistoryEntry(line: line)
            else { return }
            found.append(entry)
        }
        return found
    }

    /// The oldest line's date, read from the file's first bytes, since lines are only appended.
    static func firstDate(in prefix: Data) -> Date? {
        date(of: prefix[...])
    }

    /// The lines a rewrite keeps, byte for byte, so a later build's fields survive an older trim.
    static func kept(_ data: Data, since cutoff: Date?, removing ids: Set<UUID> = []) -> Data {
        var kept = Data()
        forEachLine(in: data) { line in
            guard let date = date(of: line), cutoff.map({ date >= $0 }) ?? true else { return }
            if !ids.isEmpty, let id = id(of: line), ids.contains(id) { return }
            kept.append(contentsOf: line)
            kept.append(newline)
        }
        return kept
    }

    /// `entry`'s line written over the one with its id, where it stands, so the order holds.
    static func replacing(_ entry: DictationHistoryEntry, in data: Data) -> Data {
        var rewritten = Data()
        forEachLine(in: data) { line in
            if id(of: line) == entry.id {
                rewritten.append(contentsOf: entry.line.utf8)
            } else {
                rewritten.append(contentsOf: line)
                rewritten.append(newline)
            }
        }
        return rewritten
    }

    private static let tab = UInt8(ascii: "\t")
    private static let newline = UInt8(ascii: "\n")

    private struct Identity: Decodable { let id: UUID }

    private static func id(of line: Data.SubSequence) -> UUID? {
        guard let tab = line.firstIndex(of: tab) else { return nil }
        return try? JSONDecoder().decode(Identity.self, from: Data(line[line.index(after: tab)...])).id
    }

    /// A last line with no newline is a write still landing, so it is not a line yet.
    private static func forEachLine(in data: Data, _ body: (Data.SubSequence) -> Void) {
        var start = data.startIndex
        while let end = data[start...].firstIndex(of: newline) {
            if end > start { body(data[start..<end]) }
            start = data.index(after: end)
        }
    }

    /// The leading seconds, up to the first tab; anything else there makes the line unreadable.
    private static func date(of line: Data.SubSequence) -> Date? {
        var seconds: Int64 = 0
        var digits = 0
        for byte in line {
            if byte == tab { return digits == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(seconds)) }
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte), digits < 12 else { return nil }
            seconds = seconds * 10 + Int64(byte - UInt8(ascii: "0"))
            digits += 1
        }
        return nil
    }
}
