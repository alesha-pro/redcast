import Foundation

/// How the Notes tools name a note, find the one meant, join added text and stay in bounds.
enum NoteToolFormat {
    enum Resolution: Equatable, Sendable {
        case found(NoteSummary)
        case ambiguous([NoteSummary])
        case missing(suggestions: [String])
    }

    static let maxSuggestions = 5
    private static let maxTitleLength = 120
    private static let snippetLead = 40

    /// File name, then title, then what an unnamed note shows: the first tier with a hit decides.
    static func resolve(_ raw: String, in summaries: [NoteSummary]) -> Resolution {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .missing(suggestions: []) }
        let key = folded(name)
        let stem = name.lowercased().hasSuffix(".md") ? folded(String(name.dropLast(3))) : key
        let tiers: [(NoteSummary) -> Bool] = [
            { $0.id.rawValue == name || $0.id.rawValue == name + ".md" },
            { [key, stem].contains(folded($0.title)) },
            { folded($0.displayTitle) == key }
        ]
        for matches in tiers {
            let hits = summaries.filter(matches)
            if hits.count == 1 { return .found(hits[0]) }
            if hits.count > 1 { return .ambiguous(hits) }
        }
        let suggestions =
            summaries
            .compactMap { summary in
                FuzzyMatch.score(query: name, candidate: summary.displayTitle).map {
                    (title: summary.displayTitle, score: $0)
                }
            }
            .sorted { $0.score > $1.score }
            .prefix(maxSuggestions)
            .map(\.title)
        return .missing(suggestions: Array(suggestions))
    }

    /// A title the folder can take as a file name: no slash, no leading dot, no `.md` twice.
    static func newTitle(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.lowercased().hasSuffix(".md") { title.removeLast(3) }
        title = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        title = String(title.drop { $0 == "." || $0.isWhitespace }.prefix(maxTitleLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Exactly one blank line before the added text, and the file still ends in a newline.
    static func appending(_ text: String, to source: String) -> String {
        let added = text.hasSuffix("\n") ? text : text + "\n"
        guard !source.isEmpty else { return added }
        let separator = source.hasSuffix("\n\n") ? "" : source.hasSuffix("\n") ? "\n" : "\n\n"
        return source + separator + added
    }

    /// The first line holding any term, cut around the hit so a long line still shows it.
    static func snippet(in source: String, terms: [String]) -> String? {
        guard !terms.isEmpty else { return nil }
        for line in source.split(whereSeparator: \.isNewline) {
            let hit = terms.lazy.compactMap {
                line.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
            }.first
            guard let hit else { continue }
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.count > NoteTools.snippetLength else { return text }
            let lead = min(snippetLead, line.distance(from: line.startIndex, to: hit.lowerBound))
            let start = line.index(hit.lowerBound, offsetBy: -lead)
            let window = line[start...].prefix(NoteTools.snippetLength - 2)
            let opening = start == line.startIndex ? "" : "…"
            let closing = window.endIndex == line.endIndex ? "" : "…"
            return opening + window.trimmingCharacters(in: .whitespaces) + closing
        }
        return nil
    }

    /// What the model calls the note back by: the shown title, with the file when they differ.
    static func name(_ summary: NoteSummary) -> String {
        summary.displayTitle == summary.title
            ? summary.displayTitle : "\(summary.displayTitle) (\(summary.id.rawValue))"
    }

    /// "Title (file.md) · modified 2026-10-21 09:14"
    static func row(_ summary: NoteSummary, timeZone: TimeZone) -> String {
        "\(name(summary)) · modified \(timestamp(summary.modifiedAt, in: timeZone))"
    }

    /// Absolute and locale-free, so a model reads the same digits on every Mac.
    static func timestamp(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0)
    }

    static func capped(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        let marker = "\n[Cut here: the rest did not fit.]"
        var kept = String.UnicodeScalarView()
        var used = 0
        for scalar in text.unicodeScalars {
            let size = String(scalar).utf8.count
            guard used + size <= bytes - marker.utf8.count else { break }
            kept.append(scalar)
            used += size
        }
        return String(kept) + marker
    }

    /// `JSONValue.intValue` traps on a number past `Int`'s range, which a model can send.
    static func integer(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value, number.isFinite else { return nil }
        return Int(min(max(number, -1_000_000_000), 1_000_000_000))
    }

    static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
    }
}
