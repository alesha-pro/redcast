import Foundation

/// What the document helper read: the pages it reached, in order, inside its byte budget.
nonisolated struct DocumentText: Codable, Equatable, Sendable {
    struct Page: Codable, Equatable, Sendable {
        /// From 1; 0 for a document without pages, as an image or a DOCX.
        let number: Int
        let text: String
        /// The page held no text of its own, so this is what OCR found on it.
        let recognized: Bool
    }

    var pageCount: Int
    var pages: [Page]
    /// The budget ran out inside the last page, whose text is cut.
    var cut: Bool

    /// Readable text only: controls but tab and newline go, and every line break becomes `\n`.
    static func cleaned(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in unified.unicodeScalars {
            switch scalar {
            case "\r", "\u{0B}", "\u{0C}", "\u{2028}", "\u{2029}": scalars.append("\n")
            case "\u{FFFC}", "\u{FEFF}": continue
            case _ where scalar.value < 0x20 && scalar != "\n" && scalar != "\t": continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// The longest prefix within `bytes` that ends on a whole scalar.
    static func prefix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: max(0, bytes))
        while String.Index(end, within: text.unicodeScalars) == nil {
            end = text.utf8.index(before: end)
        }
        return String(text.unicodeScalars[..<end])
    }

    /// A PDF's pages as the model reads them, each headed by its number, and how to read on.
    func pdfAnswer(for path: String, asked: DocumentPageRange) -> String {
        let total = "\(pageCount) page" + (pageCount == 1 ? "" : "s")
        guard let first = pages.first?.number, let last = pages.last?.number else {
            return asked.first > pageCount
                ? "\(path) has \(total); page \(asked.first) is past the end."
                : "\(path): PDF, \(total), and none of them could be read."
        }
        var text = "\(path): PDF, \(total). " + (first == last ? "Page \(first):" : "Pages \(first)–\(last):")
        for page in pages {
            let how = page.recognized ? ", scanned: its text was recognized by OCR" : ""
            text += "\n\n[Page \(page.number)\(how)]\n" + (page.text.isEmpty ? "(no text)" : page.text)
        }
        if cut { text += "\n\n[Page \(last) is cut here: the rest of it did not fit.]" }
        if last < pageCount {
            text += "\n\n[Pages \(last + 1)–\(pageCount) follow. Read on with pages "
                + "\"\(DocumentPageRange.from(last + 1))\".]"
        }
        return text
    }

    /// An image's text, which only OCR could find.
    func imageAnswer(for path: String) -> String {
        let found = pages.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !found.isEmpty else { return "No text was recognized in \(path)." }
        return "Text recognized in \(path) by OCR:\n\n" + found
    }
}
