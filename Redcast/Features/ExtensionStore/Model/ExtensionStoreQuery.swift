import Foundation

/// An entry's text folded once, so a keystroke over three thousand entries folds nothing.
struct ExtensionStoreSearchKey: Sendable {
    let title: FuzzyMatch.Candidate
    /// The slug with its dashes as spaces: "kill-process" is found by "kill process".
    let name: String
    /// Author, handle, categories, command titles and the description, in one string.
    let rest: String

    init(_ entry: ExtensionStoreEntry) {
        title = FuzzyMatch.Candidate(entry.title)
        name = FuzzyMatch.normalized(entry.name.replacingOccurrences(of: "-", with: " "))
        let parts =
            [entry.author, entry.handle] + entry.categories + entry.commands.map(\.title)
            + [entry.summary]
        rest = FuzzyMatch.normalized(parts.joined(separator: "\n"))
    }
}

/// Typed search over the loaded catalog: the title first, then every word anywhere.
enum ExtensionStoreQuery {
    /// The title's own match first, then the slug, then every word somewhere; downloads break ties.
    static func search(
        _ entries: [ExtensionStoreEntry], keys: [ExtensionStoreSearchKey], query: String
    ) -> [ExtensionStoreEntry] {
        let folded = FuzzyMatch.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !folded.isEmpty, entries.count == keys.count else { return entries }
        let fuzzy = FuzzyMatch.Query(folded)
        let words = folded.split(whereSeparator: \.isWhitespace).map(String.init)
        var ranked: [(rank: Int, entry: ExtensionStoreEntry)] = []
        for (entry, key) in zip(entries, keys) {
            if let rank = rank(key, fuzzy: fuzzy, folded: folded, words: words) {
                ranked.append((rank, entry))
            }
        }
        return ranked.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.entry.downloads != $1.entry.downloads { return $0.entry.downloads > $1.entry.downloads }
            return $0.entry.id < $1.entry.id
        }.map(\.entry)
    }

    /// Nil when some word is nowhere; subsequence matches are left out, as a store has too many.
    static func rank(
        _ key: ExtensionStoreSearchKey, fuzzy: FuzzyMatch.Query, folded: String, words: [String]
    ) -> Int? {
        if let match = FuzzyMatch.match(fuzzy, candidate: key.title) {
            switch match.tier {
            case .exact: return 0
            case .prefix: return 1
            case .wordStart: return 2
            case .substring: return 3
            case .subsequence: break
            }
        }
        if key.name.contains(folded) { return 3 }
        let everywhere = key.title.text + "\n" + key.name + "\n" + key.rest
        guard words.allSatisfy({ everywhere.contains($0) }) else { return nil }
        return words.allSatisfy({ key.title.text.contains($0) }) ? 4 : 5
    }
}
