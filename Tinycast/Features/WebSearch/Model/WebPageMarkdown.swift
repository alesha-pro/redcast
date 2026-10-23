import Foundation

/// A page as compact Markdown in one pass over its bytes: no DOM, so memory stays near the output.
nonisolated enum WebPageMarkdown {
    /// A paragraph, heading, list item, table or code block; links are markers until rendered.
    struct Block: Equatable, Sendable {
        var text: String
        /// Joined to the block before by one newline rather than a blank line, as list items are.
        var tight = false
        /// Characters of readable text, markup and addresses left out.
        var weight = 0
    }

    struct Page: Equatable, Sendable {
        var title = ""
        var summary = ""
        var blocks: [Block] = []
        /// Every distinct address a block links to; a marker names one by its index here.
        var links: [URL] = []

        var weight: Int { blocks.reduce(0) { $0 + $1.weight } }
    }

    /// A link inside a block: `start` index `middle` text `end`; these scalars never reach a part.
    static let linkStart: Unicode.Scalar = "\u{E000}"
    static let linkMiddle: Unicode.Scalar = "\u{E001}"
    static let linkEnd: Unicode.Scalar = "\u{E002}"
    /// A longer address is kept as text only: it is more likely a tracker than a page.
    static let maxLinkBytes = 1_024

    static func page(from html: String, base: URL) -> Page {
        var converter = Converter(html: Array(html.utf8), base: base, semantic: true)
        let page = converter.run()
        // An unclosed nav or hidden block swallowed the page, so read it again keeping them.
        guard converter.unclosedSkip, page.weight < WebPageTool.sparseCharacters else { return page }
        var plain = Converter(html: Array(html.utf8), base: base, semantic: false)
        let retried = plain.run()
        return retried.weight > page.weight ? retried : page
    }

    /// Text that is not HTML, one block per paragraph, so it pages the same way.
    static func page(fromText text: String) -> Page {
        var page = Page()
        for paragraph in text.components(separatedBy: "\n\n") {
            let clean = cleaned(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            page.blocks.append(Block(text: clean, weight: clean.count))
        }
        return page
    }

    /// The names pages use most; every numeric reference is decoded by its value.
    private static let entities: [Substring: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "deg": "°",
        "minus": "−", "ndash": "–", "mdash": "—", "laquo": "«", "raquo": "»", "hellip": "…",
        "copy": "©", "middot": "·", "times": "×", "rsquo": "’", "lsquo": "‘", "rdquo": "”",
        "ldquo": "“", "bull": "•", "euro": "€", "pound": "£", "shy": ""
    ]

    /// One pass, so an escaped `&amp;lt;` stays the text `&lt;` instead of becoming a `<`.
    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacing(/&(#[xX][0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z]{2,8});/) { match in
            let name = match.output.1
            guard name.hasPrefix("#") else { return entities[name] ?? String(match.output.0) }
            let digits = name.dropFirst()
            let hex = digits.first == "x" || digits.first == "X"
            let value = hex ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            guard let value, value > 0, let scalar = Unicode.Scalar(value) else {
                return String(match.output.0)
            }
            return String(Character(scalar))
        }
    }

    /// The private-use scalars a marker is made of never come from a page.
    static func cleaned(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0xE000...0xE002).contains($0.value) }) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !(0xE000...0xE002).contains($0.value) }))
    }
}

extension WebPageMarkdown {
    fileprivate nonisolated struct Converter {
        /// Code, media, controls and the head: never the page's text, whatever the page says.
        private static let dropped: Set<String> = [
            "script", "style", "noscript", "template", "iframe", "svg", "math", "object", "embed",
            "canvas", "video", "audio", "select", "textarea", "dialog", "head"
        ]
        private static let chrome: Set<String> = ["nav", "footer", "aside", "header", "menu"]
        private static let chromeRoles: Set<String> = ["navigation", "banner", "contentinfo", "complementary"]
        /// Classes MediaWiki and screen-reader conventions give text no reader of the page sees.
        private static let unseen: Set<String> = [
            "noprint", "mw-editsection", "navbox", "sr-only", "visually-hidden", "screen-reader-text",
            "catlinks", "printfooter", "mw-jump-link", "wbc-editpage"
        ]
        private static let void: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source",
            "track", "wbr"
        ]
        /// Their contents are text up to their own end tag, whatever looks like markup inside.
        private static let raw: Set<String> = ["script", "style", "textarea", "title", "xmp"]
        /// Pages leave these open, so a hidden one would hide the rest of the page.
        private static let leftOpen: Set<String> = [
            "p", "li", "dt", "dd", "tr", "td", "th", "option", "thead", "tbody", "tfoot", "colgroup"
        ]
        private static let blocks: Set<String> = [
            "p", "div", "section", "article", "main", "address", "blockquote", "figure", "figcaption",
            "details", "summary", "dl", "dt", "dd", "ul", "ol", "li", "pre", "h1", "h2", "h3", "h4",
            "h5", "h6", "hr", "form", "fieldset", "legend", "center", "caption", "header", "footer",
            "nav", "aside", "table", "tr", "body"
        ]
        /// A list left open inside one of these ends with it, as a browser ends it.
        private static let containers: Set<String> = [
            "div", "section", "article", "main", "aside", "header", "footer", "nav", "blockquote", "form",
            "figure", "details", "td", "th", "body"
        ]
        private static let attributes: Set<String> = [
            "href", "hidden", "aria-hidden", "style", "role", "alt", "name", "property", "content", "class",
            "hreflang", "aria-expanded", "aria-controls"
        ]

        private struct Table {
            var rows: [[String]] = []
            var cell: String?
            var layout = false
            var weight = 0
        }

        /// A `main`, `[role=main]` or `article` element, by the blocks written while it was open.
        private struct Region {
            let name: String
            let tag: String
            let start: Int
            var depth = 1
            var end: Int?
        }

        private let html: [UInt8]
        private var base: URL
        /// False keeps chrome and hidden elements, the retry for a page one of them swallowed.
        private let semantic: Bool
        private var page = Page()
        private var linkIndex: [String: Int] = [:]

        private var current = ""
        private var currentWeight = 0
        private var pendingSpace = false
        private var tight = false

        /// The dropped element, its own nesting, and the lists opened inside it.
        private var skip: (name: String, depth: Int, lists: Int)?
        private(set) var unclosedSkip = false
        private var heading = 0
        private var lists: [(ordered: Bool, counter: Int, depth: Int)] = []
        private var depth = 0
        private var marker: String?
        private var quotes = 0
        private var pre = 0
        private var tables: [Table] = []
        /// The open link's address, its text's byte offset in `current`, and an image's alt.
        private var link: (index: Int?, start: Int, alt: String?)?
        /// The `main` and `article` elements open now, at most one of each, so a tag never scans more.
        private var openRegions: [Region] = []
        /// The first `main` and the first `article`, which `chosen()` picks between.
        private var firstRegions: [String: Region] = [:]
        private var articles = 0

        init(html: [UInt8], base: URL, semantic: Bool) {
            self.html = html
            self.base = base
            self.semantic = semantic
        }

        mutating func run() -> Page {
            var index = 0
            let count = html.count
            var steps = 0
            while index < count {
                steps += 1
                // A stopped read keeps what it converted rather than finish a page nobody waits for.
                if steps.isMultiple(of: 4_096), Task.isCancelled { break }
                guard html[index] == UInt8(ascii: "<") else {
                    let next = html[index...].firstIndex(of: UInt8(ascii: "<")) ?? count
                    text(html[index..<next])
                    index = next
                    continue
                }
                index = tag(at: index)
            }
            unclosedSkip = skip.map { $0.name != "head" } ?? false
            while !tables.isEmpty { closeTable() }
            breakBlock()
            for region in openRegions where firstRegions[region.name] == nil { firstRegions[region.name] = region }
            page.title = decodingEntities(page.title)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            page.blocks = chosen()
            for index in page.blocks.indices.dropFirst()
            where Self.isShort(page.blocks[index]) && Self.isShort(page.blocks[index - 1]) {
                page.blocks[index].tight = true
            }
            return page
        }

        /// A figure or a label, as a forecast's cards are made of, which reads best one to a line.
        private static func isShort(_ block: Block) -> Bool {
            block.weight < 40 && !block.text.contains("\n")
                && !["#", "|", "```", "- ", "> "].contains(where: { block.text.hasPrefix($0) })
                && block.text.first.map { !$0.isNumber || !block.text.contains(". ") } ?? false
        }

        /// The main region when it holds a fifth of the text; a page of articles keeps them all.
        private func chosen() -> [Block] {
            let total = page.weight
            let candidate = firstRegions["main"] ?? (articles == 1 ? firstRegions["article"] : nil)
            guard let region = candidate, total > 0 else { return page.blocks }
            let range = region.start..<min(region.end ?? page.blocks.count, page.blocks.count)
            let weight = page.blocks[range].reduce(0) { $0 + $1.weight }
            return weight * 5 >= total ? Array(page.blocks[range]) : page.blocks
        }

        // MARK: - Tokens

        /// Past the tag at `start`, and past a raw element's text with it.
        private mutating func tag(at start: Int) -> Int {
            let count = html.count
            if starts(with: "<!--", at: start) { return find("-->", from: start + 4).map { $0 + 3 } ?? count }
            let next = start + 1
            guard next < count else {
                text(html[start..<count])
                return count
            }
            if html[next] == UInt8(ascii: "!") || html[next] == UInt8(ascii: "?") { return pastTag(from: next) }
            let closing = html[next] == UInt8(ascii: "/")
            var cursor = closing ? next + 1 : next
            guard cursor < count, Self.isLetter(html[cursor]) else {
                text(html[start..<next])
                return next
            }
            let nameStart = cursor
            while cursor < count, Self.isNameByte(html[cursor]) { cursor += 1 }
            let name = String(bytes: html[nameStart..<cursor].map(Self.lower), encoding: .utf8) ?? ""
            if closing {
                end(name)
                return pastTag(from: cursor)
            }
            var attributes: [String: String] = [:]
            var selfClosing = false
            cursor = parseAttributes(from: cursor, into: &attributes, selfClosing: &selfClosing)
            if Self.raw.contains(name), !selfClosing {
                let close = findEndTag(name, from: cursor) ?? count
                if name == "title", page.title.isEmpty, skip == nil || skip?.name == "head" {
                    page.title = String(bytes: html[cursor..<close], encoding: .utf8) ?? ""
                } else if name == "xmp" {
                    text(html[cursor..<close])
                }
                return close < count ? pastTag(from: close + 2) : count
            }
            open(name, attributes, selfClosing: selfClosing || Self.void.contains(name))
            return cursor
        }

        private func pastTag(from start: Int) -> Int {
            guard start < html.count else { return html.count }
            return (html[start...].firstIndex(of: UInt8(ascii: ">")) ?? html.count - 1) + 1
        }

        private func parseAttributes(
            from start: Int, into attributes: inout [String: String], selfClosing: inout Bool
        ) -> Int {
            var cursor = start
            let count = html.count
            while cursor < count {
                let byte = html[cursor]
                if byte == UInt8(ascii: ">") { return cursor + 1 }
                if byte == UInt8(ascii: "/") || Self.isSpace(byte) {
                    selfClosing = byte == UInt8(ascii: "/")
                    cursor += 1
                    continue
                }
                selfClosing = false
                let nameStart = cursor
                while cursor < count, !Self.isSpace(html[cursor]), !Self.endsName(html[cursor]) { cursor += 1 }
                let name = String(bytes: html[nameStart..<cursor].map(Self.lower), encoding: .utf8) ?? ""
                while cursor < count, Self.isSpace(html[cursor]) { cursor += 1 }
                guard cursor < count, html[cursor] == UInt8(ascii: "=") else {
                    if Self.attributes.contains(name), attributes[name] == nil { attributes[name] = "" }
                    continue
                }
                cursor += 1
                while cursor < count, Self.isSpace(html[cursor]) { cursor += 1 }
                guard cursor < count else { break }
                let value: ArraySlice<UInt8>
                if html[cursor] == UInt8(ascii: "\"") || html[cursor] == UInt8(ascii: "'") {
                    let quote = html[cursor]
                    let close = html[(cursor + 1)...].firstIndex(of: quote) ?? count
                    value = html[(cursor + 1)..<close]
                    cursor = min(count, close + 1)
                } else {
                    let valueStart = cursor
                    while cursor < count, !Self.isSpace(html[cursor]), html[cursor] != UInt8(ascii: ">") {
                        cursor += 1
                    }
                    value = html[valueStart..<cursor]
                }
                if Self.attributes.contains(name), attributes[name] == nil {
                    attributes[name] = decodingEntities(String(bytes: value, encoding: .utf8) ?? "")
                }
            }
            return count
        }

        // MARK: - Elements

        private mutating func open(_ name: String, _ attributes: [String: String], selfClosing: Bool) {
            if let skipping = skip {
                if (skipping.name == "head" && name == "body") || Self.isEnded(skipping, opening: name) {
                    skip = nil
                } else {
                    if name == skipping.name, !selfClosing { skip?.depth += 1 }
                    if name == "ul" || name == "ol", !selfClosing { skip?.lists += 1 }
                    if skipping.name == "head" { head(name, attributes) }
                    return
                }
            }
            if !selfClosing, dropsSubtree(name, attributes) {
                closeLink()
                skip = (name, 1, 0)
                return
            }
            if name == "base" || name == "meta" {
                head(name, attributes)
                return
            }
            if !selfClosing {
                for index in openRegions.indices where openRegions[index].tag == name { openRegions[index].depth += 1 }
            }
            if Self.blocks.contains(name) { breakBlock() }
            if Self.containers.contains(name), !selfClosing { depth += 1 }
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6": heading = Int(String(name.dropFirst())) ?? 1
            case "br": lineBreak()
            case "ul", "ol": lists.append((name == "ol", 0, depth))
            case "li":
                guard !lists.isEmpty else { break }
                lists[lists.count - 1].counter += 1
                let list = lists[lists.count - 1]
                marker = list.ordered ? "\(list.counter). " : "- "
                tight = list.counter > 1 || lists.count > 1
            case "blockquote": quotes += 1
            case "pre": pre += 1
            case "code" where pre == 0: append("`")
            case "table": openTable()
            case "tr": openRow()
            case "td", "th": openCell()
            case "a": openLink(attributes["href"])
            case "img":
                if link != nil, link?.alt == nil, let alt = attributes["alt"], !alt.isEmpty { link?.alt = alt }
            case "main", "article": openRegion(name, tag: name)
            default:
                if attributes["role"]?.lowercased() == "main", !selfClosing { openRegion("main", tag: name) }
            }
        }

        private mutating func end(_ name: String) {
            if let skipping = skip {
                if name == "ul" || name == "ol", skipping.lists > 0 { skip?.lists -= 1 }
                if Self.isEnded(skipping, closing: name) {
                    skip = nil
                } else {
                    guard name == skipping.name else { return }
                    skip?.depth -= 1
                    if skip?.depth == 0 { skip = nil }
                    return
                }
            }
            switch name {
            case "a": closeLink(final: true)
            case "code" where pre == 0: append("`")
            case "td", "th": closeCell()
            case "table": closeTable()
            default: break
            }
            if Self.blocks.contains(name) { breakBlock() }
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6": heading = 0
            case "ul", "ol":
                if !lists.isEmpty { lists.removeLast() }
                if lists.isEmpty { tight = false }
            case "li": marker = nil
            case "blockquote": quotes = max(0, quotes - 1)
            case "pre": pre = max(0, pre - 1)
            default: break
            }
            if Self.containers.contains(name), depth > 0 {
                depth -= 1
                let open = lists.count
                while let last = lists.last, last.depth > depth { lists.removeLast() }
                if lists.count < open, lists.isEmpty { tight = false }
            }
            closeRegion(name)
        }

        private func dropsSubtree(_ name: String, _ attributes: [String: String]) -> Bool {
            if Self.dropped.contains(name) { return true }
            // A heading's or a disclosure's button names a section, as an accordion's do; others are controls.
            if name == "button" {
                return heading == 0 && attributes["aria-expanded"] == nil && attributes["aria-controls"] == nil
            }
            guard semantic else { return false }
            let inside = !openRegions.isEmpty
            // An article's own header holds its title and byline, so only the site's is chrome.
            if Self.chrome.contains(name) { return !(name == "header" && inside) }
            if let role = attributes["role"]?.lowercased(), Self.chromeRoles.contains(role) {
                return !(role == "banner" && inside)
            }
            // The same page in another language, as a wiki's language list links it.
            if name == "a", attributes["hreflang"] != nil { return true }
            if let classes = attributes["class"], classes.split(separator: " ").contains(where: {
                Self.unseen.contains(String($0))
            }) {
                return true
            }
            if attributes["hidden"] != nil || attributes["aria-hidden"]?.lowercased() == "true" { return true }
            guard let style = attributes["style"]?.lowercased().replacingOccurrences(of: " ", with: "") else {
                return false
            }
            return style.contains("display:none") || style.contains("visibility:hidden")
        }

        /// A dropped element left open ends where a browser would end it: at its next sibling.
        private static func isEnded(_ skip: (name: String, depth: Int, lists: Int), opening name: String) -> Bool {
            guard skip.depth == 1, skip.lists == 0 else { return false }
            switch skip.name {
            case "p": return blocks.contains(name)
            case "li": return name == "li"
            case "dt", "dd": return name == "dt" || name == "dd"
            case "tr": return name == "tr"
            case "td", "th": return ["td", "th", "tr"].contains(name)
            case "thead", "tbody", "tfoot": return ["thead", "tbody", "tfoot"].contains(name)
            default: return false
            }
        }

        /// Or where its parent ends, though it never closed.
        private static func isEnded(_ skip: (name: String, depth: Int, lists: Int), closing name: String) -> Bool {
            guard skip.lists == 0, name != skip.name else { return false }
            switch skip.name {
            case "p": return containers.contains(name) || name == "li"
            case "li": return name == "ul" || name == "ol"
            case "dt", "dd": return name == "dl"
            case "tr", "thead", "tbody", "tfoot": return name == "table"
            case "td", "th": return name == "tr" || name == "table"
            default: return false
            }
        }

        private mutating func head(_ name: String, _ attributes: [String: String]) {
            switch name {
            case "base":
                if let href = attributes["href"], let url = URL(string: href, relativeTo: base)?.absoluteURL {
                    base = url
                }
            case "meta":
                let key = (attributes["name"] ?? attributes["property"])?.lowercased()
                guard let content = attributes["content"], !content.isEmpty else { return }
                if key == "description" || (key == "og:description" && page.summary.isEmpty) {
                    page.summary = String(cleaned(content).prefix(500))
                }
            default: break
            }
        }

        private mutating func openRegion(_ name: String, tag: String) {
            if name == "article" { articles += 1 }
            guard !openRegions.contains(where: { $0.name == name }) else { return }
            breakBlock()
            openRegions.append(Region(name: name, tag: tag, start: page.blocks.count))
        }

        private mutating func closeRegion(_ tag: String) {
            guard let index = openRegions.lastIndex(where: { $0.tag == tag }) else { return }
            openRegions[index].depth -= 1
            guard openRegions[index].depth == 0 else { return }
            breakBlock()
            var region = openRegions.remove(at: index)
            region.end = page.blocks.count
            if firstRegions[region.name] == nil { firstRegions[region.name] = region }
        }

        // MARK: - Links

        private mutating func openLink(_ href: String?) {
            closeLink(final: true)
            // Links a page sets side by side would otherwise read as one run of text.
            if current.unicodeScalars.last == linkEnd { pendingSpace = true }
            link = (address(href), current.utf8.count, nil)
        }

        /// Wraps the link's text in a marker; an image's alt names a link only when it has no text.
        private mutating func closeLink(final: Bool = true) {
            guard let open = link else { return }
            link = nil
            guard let index = open.index, open.start <= current.utf8.count else { return }
            let empty = current.utf8.dropFirst(open.start).allSatisfy { $0 == 0x20 || $0 == 0x0A }
            if empty, final, let alt = open.alt { emit(alt) }
            let start = current.utf8.index(current.utf8.startIndex, offsetBy: open.start)
            guard let first = current[start...].firstIndex(where: { !$0.isWhitespace }) else { return }
            let label = current[first...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { return }
            current.replaceSubrange(first..., with: "\(linkStart)\(index)\(linkMiddle)\(label)\(linkEnd)")
        }

        /// An http or https page other than this one; a fragment, a script or a mail link is none.
        private mutating func address(_ href: String?) -> Int? {
            guard let href = href?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty,
                !href.hasPrefix("#"), let url = URL(string: href, relativeTo: base)?.absoluteURL,
                ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil,
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return nil }
            components.fragment = nil
            guard let target = components.url, target.absoluteString.utf8.count <= maxLinkBytes else {
                return nil
            }
            let key = target.absoluteString
            if let known = linkIndex[key] { return known }
            linkIndex[key] = page.links.count
            page.links.append(target)
            return page.links.count - 1
        }

        // MARK: - Tables

        private var inCell: Bool { tables.last?.cell != nil }

        private mutating func openTable() {
            closeLink()
            guard tables.count < 4 else { return }
            if !tables.isEmpty {
                tables[tables.count - 1].layout = true
                if inCell {
                    tables[tables.count - 1].cell? += current
                    tables[tables.count - 1].weight += currentWeight
                    current = ""
                    currentWeight = 0
                }
            }
            tables.append(Table())
        }

        private mutating func openRow() {
            guard !tables.isEmpty else { return }
            closeCell()
            tables[tables.count - 1].rows.append([])
        }

        private mutating func openCell() {
            guard !tables.isEmpty else { return }
            closeCell()
            closeLink()
            if tables[tables.count - 1].rows.isEmpty { tables[tables.count - 1].rows.append([]) }
            tables[tables.count - 1].cell = ""
            current = ""
            currentWeight = 0
            pendingSpace = false
        }

        private mutating func closeCell() {
            guard let cell = tables.last?.cell else { return }
            closeLink()
            let last = tables.count - 1
            let text = (cell + current).trimmingCharacters(in: .whitespacesAndNewlines)
            tables[last].rows[tables[last].rows.count - 1].append(text)
            tables[last].cell = nil
            tables[last].weight += currentWeight
            if text.count > 400 { tables[last].layout = true }
            current = ""
            currentWeight = 0
            pendingSpace = false
        }

        /// A data table as GFM; a layout table, or one row or column, as a block per cell.
        private mutating func closeTable() {
            guard !tables.isEmpty else { return }
            closeCell()
            let table = tables.removeLast()
            let rows = table.rows.filter { $0.contains { !$0.isEmpty } }
            if inCell {
                current += " " + rows.joined().filter { !$0.isEmpty }.joined(separator: " ")
                currentWeight += table.weight
                return
            }
            let columns = rows.map(\.count).max() ?? 0
            guard !table.layout, rows.count >= 2, columns >= 2 else {
                for cell in rows.joined() where !cell.isEmpty {
                    page.blocks.append(Block(text: cell, weight: cell.count))
                }
                return
            }
            func line(_ row: [String]) -> String {
                let cells = row + Array(repeating: "", count: columns - row.count)
                return "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ")
                    + " |"
            }
            let lines = [line(rows[0]), line(Array(repeating: "---", count: columns))] + rows.dropFirst().map(line)
            page.blocks.append(Block(text: lines.joined(separator: "\n"), weight: table.weight))
        }

        // MARK: - Text

        private mutating func text(_ bytes: ArraySlice<UInt8>) {
            guard skip == nil, !bytes.isEmpty else { return }
            emit(cleaned(decodingEntities(String(bytes: bytes, encoding: .utf8) ?? "")))
        }

        private mutating func emit(_ text: String) {
            if pre > 0, !inCell {
                current += text
                currentWeight += text.count
                return
            }
            for character in text {
                if character.isWhitespace {
                    pendingSpace = true
                    continue
                }
                if pendingSpace, let last = current.last, !last.isWhitespace { current += " " }
                pendingSpace = false
                current.append(character)
                currentWeight += 1
            }
        }

        private mutating func append(_ markup: String) {
            if pendingSpace, let last = current.last, !last.isWhitespace { current += " " }
            pendingSpace = false
            current += markup
        }

        private mutating func lineBreak() {
            if inCell {
                pendingSpace = true
            } else if pre > 0 {
                current += "\n"
            } else {
                breakBlock()
                tight = true
            }
        }

        /// Ends the block being written; inside a cell a block is only a space.
        private mutating func breakBlock() {
            guard !inCell else {
                pendingSpace = true
                return
            }
            let pending = link
            closeLink(final: false)
            let body = pre > 0 ? current.trimmingCharacters(in: .newlines) : current.trimmingCharacters(in: .whitespaces)
            let weight = currentWeight
            current = ""
            currentWeight = 0
            pendingSpace = false
            if let pending { link = (pending.index, 0, pending.alt) }
            guard !body.allSatisfy(\.isWhitespace) else { return }
            var prefix = String(repeating: "> ", count: quotes)
            if let marker {
                prefix += String(repeating: "  ", count: max(0, min(lists.count, 8) - 1)) + marker
                self.marker = nil
            } else if !lists.isEmpty {
                prefix += String(repeating: "  ", count: min(lists.count, 8))
            }
            if heading > 0 { prefix += String(repeating: "#", count: heading) + " " }
            let text = pre > 0 ? "```\n" + body + "\n```" : prefix + body
            page.blocks.append(Block(text: text, tight: tight && pre == 0, weight: weight))
            tight = !lists.isEmpty
        }

        // MARK: - Bytes

        private func starts(with literal: String, at index: Int) -> Bool {
            let bytes = Array(literal.utf8)
            guard index + bytes.count <= html.count else { return false }
            return html[index..<(index + bytes.count)].elementsEqual(bytes)
        }

        private func find(_ literal: String, from index: Int) -> Int? {
            let bytes = Array(literal.utf8)
            var cursor = index
            while cursor + bytes.count <= html.count {
                guard let next = html[cursor...].firstIndex(of: bytes[0]) else { return nil }
                if next + bytes.count <= html.count, html[next..<(next + bytes.count)].elementsEqual(bytes) {
                    return next
                }
                cursor = next + 1
            }
            return nil
        }

        /// `</name` and a boundary, in any case; a raw element's text may hold anything else.
        private func findEndTag(_ name: String, from index: Int) -> Int? {
            let bytes = Array(name.utf8)
            var cursor = index
            while let open = find("</", from: cursor) {
                let nameEnd = open + 2 + bytes.count
                guard nameEnd <= html.count else { return nil }
                let matches = zip(html[(open + 2)..<nameEnd], bytes).allSatisfy { Self.lower($0) == $1 }
                if matches, nameEnd == html.count || !Self.isNameByte(html[nameEnd]) { return open }
                cursor = open + 2
            }
            return nil
        }

        private static func lower(_ byte: UInt8) -> UInt8 {
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
        }

        private static func isLetter(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(lower(byte))
        }

        private static func isNameByte(_ byte: UInt8) -> Bool {
            isLetter(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ":")
        }

        private static func endsName(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: "=") || byte == UInt8(ascii: ">") || byte == UInt8(ascii: "/")
        }

        private static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
        }
    }
}
