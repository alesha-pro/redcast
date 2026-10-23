import Foundation

/// The pages a read asks for, from 1: "3", "3-5" or "7-"; an open end reads as many as fit.
nonisolated struct DocumentPageRange: Codable, Equatable, Sendable {
    let first: Int
    let last: Int?

    static let all = DocumentPageRange(first: 1, last: nil)
    /// OCR takes about a second a scanned page, so a read stops well inside the helper's timeout.
    static let maxPages = 50

    init(first: Int, last: Int?) {
        let start = max(1, first)
        self.first = start
        self.last = last.map { max(start, $0) }
    }

    /// Nil for anything but a page, a closed range or an open one; a dash may be an en dash.
    init?(_ text: String) {
        let parts = text.replacingOccurrences(of: "–", with: "-")
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first.flatMap({ Int($0) }), first >= 1 else { return nil }
        guard parts.count == 2 else {
            self.init(first: first, last: first)
            return
        }
        if parts[1].isEmpty {
            self.init(first: first, last: nil)
            return
        }
        guard let last = Int(parts[1]), last >= first else { return nil }
        self.init(first: first, last: last)
    }

    /// The pages a read may reach in a document of `count` pages; nil when it starts past the end.
    func clamped(to count: Int) -> ClosedRange<Int>? {
        guard first <= count else { return nil }
        return first...min(count, last ?? count, first + Self.maxPages - 1)
    }

    /// How the model writes it back to read on.
    static func from(_ page: Int) -> String { "\(page)-" }
}
