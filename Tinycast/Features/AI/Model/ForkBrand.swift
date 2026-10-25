import Foundation

/// Fork: Redcast for Tinycast in text no catalog holds; here so prompt harnesses compile it.
enum ForkBrand {
    static let name = "Redcast"
    static let upstreamName = "Tinycast"

    /// Whole capitalised words, as rebrand.mjs renames them; ids, paths and schemes stay.
    static func renamed(_ text: String) -> String {
        var result = ""
        var rest = text[...]
        while let found = rest.range(of: upstreamName) {
            result += rest[..<found.lowerBound]
            result += isWhole(found, in: text) ? name : upstreamName
            rest = rest[found.upperBound...]
        }
        return result + rest
    }

    private static func isWhole(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.isLetter || before.isNumber || "_./".contains(before) { return false }
        }
        var end = range.upperBound
        if end < text.endIndex, text[end] == "s" { end = text.index(after: end) }
        guard end < text.endIndex else { return true }
        let after = text[end]
        return !(after.isLetter || after.isNumber || "_/".contains(after))
    }
}

extension String {
    /// Upstream's text with Redcast for Tinycast.
    var forkBranded: String { ForkBrand.renamed(self) }
}
