import Foundation

/// What an ACP tool call showed, its diffs and its output, compacted to what its row unfolds.
struct ChatToolContent: Codable, Hashable, Sendable {
    struct Diff: Codable, Hashable, Sendable {
        let path: String
        /// One line per row, led by `-`, `+` or a space; a `cutMarker` line counts lines left out.
        let lines: String
    }

    enum Line: Hashable, Sendable {
        case context(String)
        case removed(String)
        case added(String)
        case text(String)
        case cut(Int)
    }

    var diffs: [Diff] = []
    /// Diff blocks beyond the ones kept, said rather than dropped silently.
    var omittedDiffs = 0
    var output: String?

    /// A control character, so no line of real text that compaction kept can be read as a cut.
    static let cutMarker: Character = "\u{1F}"

    var isEmpty: Bool { diffs.isEmpty && output == nil }

    static func lines(of diff: Diff) -> [Line] {
        diff.lines.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let lead = line.first else { return .context("") }
            let rest = String(line.dropFirst())
            switch lead {
            case "-": return .removed(rest)
            case "+": return .added(rest)
            case cutMarker: return .cut(Int(rest) ?? 0)
            default: return .context(rest)
            }
        }
    }

    var outputLines: [Line] {
        (output ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.first == Self.cutMarker ? .cut(Int(line.dropFirst()) ?? 0) : .text(String(line))
        }
    }

    /// Stored as JSON beside its row; an unreadable one leaves the row without content.
    var encoded: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    init(diffs: [Diff] = [], omittedDiffs: Int = 0, output: String? = nil) {
        self.diffs = diffs
        self.omittedDiffs = omittedDiffs
        self.output = output
    }

    init?(encoded: String) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: Data(encoded.utf8)) else {
            return nil
        }
        self = decoded
    }

    /// Every field optional on the way in, so a row written by a later build still opens here.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        diffs = try container.decodeIfPresent([Diff].self, forKey: .diffs) ?? []
        omittedDiffs = try container.decodeIfPresent(Int.self, forKey: .omittedDiffs) ?? 0
        output = try container.decodeIfPresent(String.self, forKey: .output)
    }
}
