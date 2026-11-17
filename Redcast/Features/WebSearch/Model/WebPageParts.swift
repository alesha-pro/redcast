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
        let links = page.links
        var blocks: [WebPageMarkdown.Block] = []
        var ranges: [Range<Int>] = []
        var start = 0
        var size = 0
        var used = Set<Int>()
        /// Into the part being filled when it fits there; `force` puts a piece in an empty part.
        func add(_ block: WebPageMarkdown.Block, force: Bool = false) -> Bool {
            var trial = used
            let bytes = Self.render(block.text, links: links, used: &trial).text.utf8.count
            let joint = blocks.count == start ? 0 : (block.tight ? 1 : 2)
            guard size + joint + bytes <= limit || (force && blocks.count == start) else { return false }
            blocks.append(block)
            size += joint + bytes
            used = trial
            return true
        }
        func close() {
            guard blocks.count > start else { return }
            ranges.append(start..<blocks.count)
            start = blocks.count
            size = 0
            used = []
        }
        for block in page.blocks {
            if add(block) { continue }
            if Self.upperBound(block.text, links: links) <= limit {
                close()
                _ = add(block, force: true)
                continue
            }
            // Too long for any part, so its first piece fills what this part has left.
            var room = limit - size - (blocks.count == start ? 0 : (block.tight ? 1 : 2))
            if room < limit / 4 {
                close()
                room = limit
            }
            for piece in Self.pieces(of: block, first: room, limit: limit, links: links) {
                if add(piece) { continue }
                close()
                _ = add(piece, force: true)
            }
        }
        close()
        self.blocks = blocks
        self.links = links
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

    /// A block too long for one part: a table by rows under its header, else cut between words.
    private static func pieces(
        of block: WebPageMarkdown.Block, first: Int, limit: Int, links: [URL]
    ) -> [WebPageMarkdown.Block] {
        if let rows = rows(of: block, first: first, limit: limit, links: links) { return rows }
        let units = units(of: block.text)
        let sizes = units.map { upperBound($0, links: links) }
        var pieces: [WebPageMarkdown.Block] = []
        var piece = ""
        var size = 0
        var budget = min(first, limit)
        func flush() {
            let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                pieces.append(.init(text: text, tight: pieces.isEmpty ? block.tight : true, weight: text.count))
            }
            piece = ""
            size = 0
            budget = limit
        }
        for (unit, unitSize) in zip(units, sizes) {
            if size + unitSize > budget { flush() }
            guard unitSize > budget else {
                piece += unit
                size += unitSize
                continue
            }
            // Too long even alone, so its link is dropped and the text cut where the bytes run out.
            var none = Set(links.indices)
            var rest = Substring(render(unit, links: links, used: &none).text)
            while !rest.isEmpty {
                let cut = prefix(rest, bytes: budget)
                piece = String(cut)
                flush()
                rest = rest[cut.endIndex...]
            }
        }
        flush()
        return pieces
    }

    /// A Markdown table cut between rows, each piece under the header again; nil for any other block.
    private static func rows(
        of block: WebPageMarkdown.Block, first: Int, limit: Int, links: [URL]
    ) -> [WebPageMarkdown.Block]? {
        let lines = block.text.components(separatedBy: "\n")
        guard lines.count > 3, lines[0].hasPrefix("| "), lines[1].hasPrefix("| --- |") else { return nil }
        let header = lines[0] + "\n" + lines[1]
        let headerSize = upperBound(header, links: links)
        let sizes = lines.dropFirst(2).map { upperBound($0, links: links) + 1 }
        // A row that fits no part under the header is cut between words instead.
        guard sizes.allSatisfy({ headerSize + $0 <= limit }) else { return nil }
        var pieces: [WebPageMarkdown.Block] = []
        var piece = header
        var size = headerSize
        var budget = headerSize + sizes[0] <= first ? first : limit
        for (row, rowSize) in zip(lines.dropFirst(2), sizes) {
            if size + rowSize > budget {
                pieces.append(.init(text: piece, tight: pieces.isEmpty && block.tight, weight: piece.count))
                piece = header
                size = headerSize
                budget = limit
            }
            piece += "\n" + row
            size += rowSize
        }
        pieces.append(.init(text: piece, tight: pieces.isEmpty && block.tight, weight: piece.count))
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
