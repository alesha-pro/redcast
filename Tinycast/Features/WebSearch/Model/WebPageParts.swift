import Foundation

/// A converted page cut at block edges into parts that fit one tool result; links render per part.
nonisolated struct WebPageParts: Sendable {
    /// Under the 28 KB a tool's own cut allows, with room for the notice, title and how to read on.
    static let partBytes = 24 * 1_024

    let blocks: [WebPageMarkdown.Block]
    let links: [URL]
    /// Block ranges, one per part, in order; empty for a page without text.
    let ranges: [Range<Int>]

    var count: Int { ranges.count }

    init(_ page: WebPageMarkdown.Page, partBytes: Int = Self.partBytes) {
        let limit = max(256, partBytes)
        let blocks = page.blocks.flatMap { Self.pieces(of: $0, limit: limit, links: page.links) }
        var ranges: [Range<Int>] = []
        var start = 0
        var size = 0
        var used = Set<Int>()
        for (index, block) in blocks.enumerated() {
            var trial = used
            var bytes = Self.render(block.text, links: page.links, used: &trial).text.utf8.count
            let joint = index == start ? 0 : (block.tight ? 1 : 2)
            if index > start, size + joint + bytes > limit {
                ranges.append(start..<index)
                start = index
                trial = []
                bytes = Self.render(block.text, links: page.links, used: &trial).text.utf8.count
                size = bytes
            } else {
                size += joint + bytes
            }
            used = trial
        }
        if start < blocks.count { ranges.append(start..<blocks.count) }
        self.blocks = blocks
        self.links = page.links
        self.ranges = ranges
    }

    /// Part `number`, from 1, as Markdown: each address linked where it first appears in the part.
    func part(_ number: Int) -> (text: String, links: [URL])? {
        guard ranges.indices.contains(number - 1) else { return nil }
        var used = Set<Int>()
        var text = ""
        var kept: [URL] = []
        for index in ranges[number - 1] {
            let block = blocks[index]
            let rendered = Self.render(block.text, links: links, used: &used)
            if !text.isEmpty { text += block.tight ? "\n" : "\n\n" }
            text += rendered.text
            kept += rendered.links
        }
        return (text, kept)
    }

    /// Markers as `[text](address)` the first time an address appears, as plain text after that.
    static func render(_ text: String, links: [URL], used: inout Set<Int>) -> (text: String, links: [URL]) {
        guard text.unicodeScalars.contains(WebPageMarkdown.linkStart) else { return (text, []) }
        var output = String.UnicodeScalarView()
        var kept: [URL] = []
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == WebPageMarkdown.linkStart else {
                output.append(scalar)
                continue
            }
            var digits = ""
            while let next = scalars.next(), next != WebPageMarkdown.linkMiddle { digits.unicodeScalars.append(next) }
            var label = String.UnicodeScalarView()
            while let next = scalars.next(), next != WebPageMarkdown.linkEnd { label.append(next) }
            let name = String(label)
            guard let index = Int(digits), links.indices.contains(index), used.insert(index).inserted else {
                output.append(contentsOf: name.unicodeScalars)
                continue
            }
            kept.append(links[index])
            let escaped = name.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            output.append(contentsOf: "[\(escaped)](\(links[index].absoluteString))".unicodeScalars)
        }
        return (String(output), kept)
    }

    /// A block too long for one part, cut between words, each piece within `limit` linked in full.
    private static func pieces(
        of block: WebPageMarkdown.Block, limit: Int, links: [URL]
    ) -> [WebPageMarkdown.Block] {
        let units = units(of: block.text)
        let sizes = units.map { upperBound($0, links: links) }
        guard sizes.reduce(0, +) > limit else { return [block] }
        var pieces: [WebPageMarkdown.Block] = []
        var piece = ""
        var size = 0
        func flush() {
            let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                pieces.append(.init(text: text, tight: pieces.isEmpty ? block.tight : true, weight: text.count))
            }
            piece = ""
            size = 0
        }
        for (unit, unitSize) in zip(units, sizes) {
            if size + unitSize > limit { flush() }
            guard unitSize > limit else {
                piece += unit
                size += unitSize
                continue
            }
            // Too long even alone, so its link is dropped and the text cut where the bytes run out.
            var none = Set(links.indices)
            var rest = Substring(render(unit, links: links, used: &none).text)
            while !rest.isEmpty {
                let cut = prefix(rest, bytes: limit)
                piece = String(cut)
                flush()
                rest = rest[cut.endIndex...]
            }
        }
        flush()
        return pieces
    }

    /// Words with the space or newline after them, and each link whole, so no cut splits a marker.
    private static func units(of text: String) -> [String] {
        var units: [String] = []
        var unit = String.UnicodeScalarView()
        var inLink = false
        for scalar in text.unicodeScalars {
            unit.append(scalar)
            if scalar == WebPageMarkdown.linkStart { inLink = true }
            if scalar == WebPageMarkdown.linkEnd { inLink = false }
            if !inLink, scalar == " " || scalar == "\n" || scalar == WebPageMarkdown.linkEnd {
                units.append(String(unit))
                unit = String.UnicodeScalarView()
            }
        }
        if !unit.isEmpty { units.append(String(unit)) }
        return units
    }

    /// The bytes a unit takes when every link in it renders in full.
    private static func upperBound(_ unit: String, links: [URL]) -> Int {
        var used = Set<Int>()
        return render(unit, links: links, used: &used).text.utf8.count
    }

    /// At most `bytes`, ending on a whole scalar.
    private static func prefix(_ text: Substring, bytes: Int) -> Substring {
        guard text.utf8.count > bytes else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: max(1, bytes))
        while end > text.startIndex, String.Index(end, within: text) == nil {
            end = text.utf8.index(before: end)
        }
        return text[..<end]
    }
}
