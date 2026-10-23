import Foundation

/// An entry's searchable text, folded once per load so a keystroke folds only the query.
struct DictationHistorySearchKey: Sendable {
    let folded: String

    init(_ entry: DictationHistoryEntry) {
        let fields = [entry.text, entry.transcript, entry.appName, entry.mode].compactMap { $0 }
        folded = DictationHistoryQuery.fold(fields.joined(separator: "\n"))
    }
}

/// Every word typed must appear somewhere in an entry; the order stays the caller's, newest first.
enum DictationHistoryQuery {
    /// Locale-independent, so a Turkish interface never folds "I" into a different letter.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
    }

    static func filter(
        _ entries: [DictationHistoryEntry], keys: [DictationHistorySearchKey], query: String
    ) -> [DictationHistoryEntry] {
        let terms = terms(query)
        guard !terms.isEmpty else { return entries }
        return zip(entries, keys).compactMap { entry, key in
            terms.allSatisfy { key.folded.contains($0) } ? entry : nil
        }
    }
}
