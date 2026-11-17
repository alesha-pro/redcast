import Foundation

/// A call's content compacted once, as it arrives, so a row never holds more than it shows.
extension ChatToolContent {
    static let maxDiffs = 6
    static let maxDiffLines = 60
    static let contextLines = 2
    static let maxOutputLines = 80
    static let maxLineLength = 240
    /// What one row may hold, and so what one row persists, diffs and output together.
    static let maxBytes = 12 * 1_024
    /// Diffs stop here, so a call with both still has room left for its output.
    static let maxDiffBytes = 8 * 1_024
    /// Beyond this many cells the line diff gives up and shows the old block, then the new.
    static let maxDiffCells = 160 * 160

    /// Nil when the call carried no content a text transcript can show.
    init?(call: ACPToolCall) {
        var diffBudget = Self.maxDiffBytes
        var diffs: [Diff] = []
        for diff in call.diffs.prefix(Self.maxDiffs) {
            let lines = Self.compactDiff(old: diff.oldText, new: diff.newText)
            let path = diff.path.count <= Self.maxLineLength
                ? diff.path : "…" + String(diff.path.suffix(Self.maxLineLength - 1))
            diffBudget -= path.utf8.count
            diffs.append(Diff(path: path, lines: Self.joined(lines, prefixed: true, budget: &diffBudget)))
        }
        var budget = Self.maxBytes - (Self.maxDiffBytes - diffBudget)
        let output = call.text
            .flatMap { Self.compactOutput($0, keepsTail: call.kind == "execute") }
            .map { Self.joined($0, prefixed: false, budget: &budget) }
        self.init(
            diffs: diffs, omittedDiffs: max(call.diffs.count - Self.maxDiffs, 0),
            output: output?.isEmpty == false ? output : nil)
        if isEmpty { return nil }
    }

    enum Row: Equatable {
        case context(Substring)
        case removed(Substring)
        case added(Substring)
        case cut(Int)

        var isChange: Bool {
            switch self {
            case .removed, .added: true
            case .context, .cut: false
            }
        }

        var hidden: Int {
            if case .cut(let count) = self { count } else { 1 }
        }
    }

    // MARK: - Diffs

    /// The changed lines with `contextLines` of context each side; a new file is all additions.
    static func compactDiff(old: String?, new: String) -> [Row] {
        let before = old.map(splitLines) ?? []
        let after = splitLines(new)
        var head = 0
        while head < before.count, head < after.count, before[head] == after[head] { head += 1 }
        var tail = 0
        while tail < before.count - head, tail < after.count - head,
            before[before.count - 1 - tail] == after[after.count - 1 - tail]
        {
            tail += 1
        }
        let middle = changes(
            before[head..<(before.count - tail)], after[head..<(after.count - tail)])
        let all =
            before[..<head].map(Row.context) + middle
            + before[(before.count - tail)...].map(Row.context)
        return capped(collapsingContext(all), at: maxDiffLines)
    }

    /// A longest-common-subsequence walk; past `maxDiffCells` the blocks are shown whole.
    private static func changes(_ old: ArraySlice<Substring>, _ new: ArraySlice<Substring>) -> [Row] {
        let old = Array(old)
        let new = Array(new)
        guard old.count * new.count <= maxDiffCells else {
            return old.map(Row.removed) + new.map(Row.added)
        }
        let width = new.count + 1
        var common = [UInt16](repeating: 0, count: (old.count + 1) * width)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                common[i * width + j] =
                    old[i] == new[j]
                    ? common[(i + 1) * width + j + 1] + 1
                    : max(common[(i + 1) * width + j], common[i * width + j + 1])
            }
        }
        var rows: [Row] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] {
                rows.append(.context(old[i]))
                i += 1
                j += 1
            } else if i < old.count,
                j == new.count || common[(i + 1) * width + j] >= common[i * width + j + 1]
            {
                rows.append(.removed(old[i]))
                i += 1
            } else {
                rows.append(.added(new[j]))
                j += 1
            }
        }
        return rows
    }

    /// Unchanged lines far from any change fold into one cut; a cut of one line stays a line.
    private static func collapsingContext(_ rows: [Row]) -> [Row] {
        var keep = [Bool](repeating: false, count: rows.count)
        for (index, row) in rows.enumerated() where row.isChange {
            let near = max(index - contextLines, 0)...min(index + contextLines, rows.count - 1)
            for neighbour in near { keep[neighbour] = true }
        }
        guard keep.contains(true) else { return [] }
        var kept: [Row] = []
        var folded: [Row] = []
        for (index, row) in rows.enumerated() {
            if keep[index] {
                kept += folded.count == 1 ? folded : folded.isEmpty ? [] : [.cut(folded.count)]
                folded = []
                kept.append(row)
            } else {
                folded.append(row)
            }
        }
        kept += folded.count == 1 ? folded : folded.isEmpty ? [] : [.cut(folded.count)]
        return kept
    }

    // MARK: - Output

    /// A command keeps more of its end, where errors land; anything else more of its start.
    static func compactOutput(_ text: String, keepsTail: Bool) -> [Row]? {
        var lines = splitLines(text)[...]
        if let first = lines.first, first.hasPrefix("```"), lines.count > 1,
            lines.last?.trimmingCharacters(in: .whitespaces) == "```"
        {
            lines = lines.dropFirst().dropLast()
        }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines = lines.dropLast() }
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines = lines.dropFirst() }
        guard !lines.isEmpty else { return nil }
        let rows: [Row]
        if lines.count > maxOutputLines {
            let head = keepsTail ? maxOutputLines / 4 : maxOutputLines * 3 / 4
            let tail = maxOutputLines - head
            rows = lines.prefix(head).map(Row.context) + [.cut(lines.count - head - tail)]
                + lines.suffix(tail).map(Row.context)
        } else {
            rows = lines.map(Row.context)
        }
        return rows.map { row in
            guard case .context(let line) = row else { return row }
            // Clipped first, so one minified megabyte is not cleaned whole only to be cut.
            return .context(Substring(plain(String(line.prefix(maxLineLength * 4)))))
        }
    }

    /// Escape sequences and other controls dropped; a carriage return keeps what overwrote it.
    static func plain(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        var pending = scalars.next()
        while let scalar = pending {
            pending = scalars.next()
            switch scalar.value {
            case 0x1B:
                pending = skipEscape(after: pending, in: &scalars)
            case 0x09:
                result.append(scalar)
            case 0x0D:
                result.removeAll()
            case 0..<0x20, 0x7F:
                continue
            default:
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// CSI runs to its final byte, OSC to its bell or string terminator, anything else one scalar.
    private static func skipEscape(
        after next: Unicode.Scalar?, in scalars: inout String.UnicodeScalarView.Iterator
    ) -> Unicode.Scalar? {
        switch next?.value {
        case 0x5B:
            while let scalar = scalars.next(), !(0x40...0x7E).contains(scalar.value) {}
        case 0x5D:
            while let scalar = scalars.next(), scalar.value != 0x07 {
                if scalar.value == 0x1B {
                    _ = scalars.next()
                    break
                }
            }
        default:
            break
        }
        return scalars.next()
    }

    // MARK: - Shared

    /// Views cut at newline bytes, which always end a grapheme; walking graphemes is the slow part.
    private static func splitLines(_ text: String) -> [Substring] {
        var text = text
        // A bridged NSString from the JSON is transcoded once rather than read through the bridge.
        text.makeContiguousUTF8()
        var lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { line in
            Substring(line.last == 0x0D ? line.dropLast() : line)
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    private static func capped(_ rows: [Row], at limit: Int) -> [Row] {
        guard rows.count > limit else { return rows }
        return Array(rows.prefix(limit - 1)) + [.cut(rows[(limit - 1)...].reduce(0) { $0 + $1.hidden })]
    }

    /// The stored form; once the budget is spent, the rest of the rows become one cut.
    private static func joined(_ rows: [Row], prefixed: Bool, budget: inout Int) -> String {
        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            let line =
                switch row {
                case .context(let text): (prefixed ? " " : "") + clipped(text)
                case .removed(let text): "-" + clipped(text)
                case .added(let text): "+" + clipped(text)
                case .cut(let count): String(cutMarker) + String(count)
                }
            guard line.utf8.count + 1 <= budget else {
                lines.append(String(cutMarker) + String(rows[index...].reduce(0) { $0 + $1.hidden }))
                budget = 0
                break
            }
            budget -= line.utf8.count + 1
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func clipped(_ text: Substring) -> String {
        text.count <= maxLineLength ? String(text) : text.prefix(maxLineLength - 1) + "…"
    }
}
