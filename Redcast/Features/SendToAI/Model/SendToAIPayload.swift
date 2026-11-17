import Foundation

/// One row a screen hands to Send to AI, in plain values so no screen type reaches the payload.
enum SendToAISource: Equatable, Sendable {
    /// A clipboard text entry; a colour is recognised from its text.
    case text(String)
    /// A clipboard image, by the file it was saved to.
    case image(path: String)
    case file(path: String, isDirectory: Bool)
    /// A dictation's text, and for Ask by Voice the question it answered.
    case dictation(text: String, request: String?)
}

/// What Quick AI or a new chat is handed: files for the composer's reader, notes and a draft.
struct SendToAIPayload: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text, color, image, file, folder, dictation
    }

    /// Text staged as a file of its own, as Screen Awareness stages a window's text.
    struct Note: Equatable, Sendable {
        let name: String
        let text: String
    }

    let kind: Kind
    /// Absolute paths, read by the composer's own attachment path with its refusals.
    var files: [String] = []
    var notes: [Note] = []
    /// Typed into the composer, ending in a space so the question follows it.
    var draft = ""

    /// Quick AI's composer is the palette's one-line field, so only a short line is quoted.
    static let maxQuotedLength = 200
    static let cutMarker = "\n\n[Cut here: the rest did not fit.]"

    /// Nil when the row holds nothing to send; `maxNoteBytes` is the composer's inlined-text cap.
    static func make(for source: SendToAISource, maxNoteBytes: Int) -> Self? {
        switch source {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let color = ColorValue.parse(trimmed) {
                return Self(kind: .color, draft: colorDraft(trimmed, color))
            }
            return quotedOrNoted(trimmed, kind: .text, name: "Clipboard.txt", maxNoteBytes: maxNoteBytes)
        case .image(let path):
            return path.isEmpty ? nil : Self(kind: .image, files: [path])
        case .file(let path, let isDirectory):
            guard !path.isEmpty else { return nil }
            // A folder is no attachment, so its path is what the model is told.
            return isDirectory
                ? Self(kind: .folder, draft: quoted(path)) : Self(kind: .file, files: [path])
        case .dictation(let text, let request):
            let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !said.isEmpty else { return nil }
            let asked = request?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard asked.isEmpty else {
                let exchange = "Question: \(asked)\n\nAnswer: \(said)"
                return Self(
                    kind: .dictation,
                    notes: [Note(name: "Voice question.txt", text: capped(exchange, to: maxNoteBytes))])
            }
            return quotedOrNoted(said, kind: .dictation, name: "Dictation.txt", maxNoteBytes: maxNoteBytes)
        }
    }

    private static func quotedOrNoted(
        _ text: String, kind: Kind, name: String, maxNoteBytes: Int
    ) -> Self {
        // Bytes first: counting a long clip's characters would walk all of it.
        let isShortLine =
            text.utf8.count <= maxQuotedLength * 4 && text.count <= maxQuotedLength
            && !text.contains(where: \.isNewline)
        guard isShortLine else {
            return Self(kind: kind, notes: [Note(name: name, text: capped(text, to: maxNoteBytes))])
        }
        return Self(kind: kind, draft: quoted(text))
    }

    private static func quoted(_ text: String) -> String { "\"\(text)\" " }

    /// The colour as copied, with its hex beside it when it was written another way.
    private static func colorDraft(_ text: String, _ color: ColorValue) -> String {
        let hex = ColorFormat.primary(for: color).string(for: color)
        return text.caseInsensitiveCompare(hex) == .orderedSame ? "\(text) " : "\(text) (\(hex)) "
    }

    static func capped(_ text: String, to maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var kept = ""
        var used = cutMarker.utf8.count
        for character in text {
            let size = character.utf8.count
            guard used + size <= maxBytes else { break }
            kept.append(character)
            used += size
        }
        return kept + cutMarker
    }
}
