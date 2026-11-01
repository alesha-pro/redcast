import Foundation

/// What the composer's chrome asks of a draft; each answer costs the same at any draft's length.
struct ChatDraftFacts: Equatable, Sendable {
    /// Enough for any `@server` or `/command` the composer recognises at the draft's start.
    static let headLength = 256
    /// Characters on one line at any width; a layout may propose an infinite one.
    private static let longestLine: CGFloat = 10_000

    let isEmpty: Bool
    let isBlank: Bool
    /// Only a draft that opens with `@` or `/` has one, so plain typing never moves it.
    let head: String

    init(_ text: String) {
        isEmpty = text.isEmpty
        isBlank = !text.contains { !$0.isWhitespace }
        let start = Self.prefix(of: text, length: Self.headLength)
        let opening = start.first { $0 != " " }
        head = opening == "@" || opening == "/" ? start : ""
    }

    /// The part of a draft that can show in `lines` lines, enough to tell it fills them.
    static func measuredPart(
        of text: String, lines: CGFloat, width: CGFloat, narrowestGlyph: CGFloat
    ) -> String {
        let lineCount = max(Int(lines), 1)
        let perLine = min((width / max(narrowestGlyph, 1)).rounded(.up), longestLine)
        var start = prefix(of: text, length: lineCount * max(Int(perLine), 1))
        // Past that many line breaks the field is full, however short the lines.
        let fullAt = start.withUTF8 { bytes -> Int? in
            var breaks = 0
            for (offset, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
                breaks += 1
                if breaks > lineCount { return offset }
            }
            return nil
        }
        guard let fullAt else { return start }
        return String(start[..<start.utf8.index(start.startIndex, offsetBy: fullAt)])
    }

    /// By UTF-16, which a bridged string answers at once; a grapheme walk would cost per character.
    private static func prefix(of text: String, length: Int) -> String {
        let utf16 = text.utf16
        guard let end = utf16.index(utf16.startIndex, offsetBy: length, limitedBy: utf16.endIndex),
            end != utf16.endIndex
        else { return text }
        return String(text[..<end])
    }
}
