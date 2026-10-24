import AppKit

/// A reply's existing files as links in its text, each led by a small icon of what it is.
@MainActor
enum ChatFileLinker {
    /// The kind on a linked run, read back once citations have moved the text around it.
    private static let kindKey = NSAttributedString.Key("TinycastChatFileKind")

    /// Before citations: `parsed` lines up with `text` only until they are inserted.
    static func link(_ text: NSMutableAttributedString, parsed: AttributedString, files: ChatFileLinks?) {
        guard let files, !files.byMention.isEmpty else { return }
        var location = 0
        for run in parsed.runs {
            let runText = String(parsed[run.range].characters)
            let isFormula = run[MathFormula.Attribute.self] != nil
            // A formula draws one attachment per character, as the renderer lays it out.
            let length = isFormula ? runText.count : runText.utf16.count
            defer { location += length }
            guard !isFormula else { continue }
            let whole = NSRange(location: location, length: length)
            if let url = run.link {
                if let item = ChatFileMentions.linkKey(url.absoluteString).flatMap({ files.byMention[$0] }) {
                    apply(item, to: whole, in: text)
                }
            } else if run.inlinePresentationIntent?.contains(.code) == true {
                if let item = ChatFileMentions.codeKey(runText).flatMap({ files.byMention[$0] }) {
                    apply(item, to: whole, in: text)
                }
            } else {
                for range in ChatFileMentions.barePaths(in: runText) {
                    guard let item = files.byMention[String(runText[range])] else { continue }
                    let span = NSRange(range, in: runText)
                    let shifted = NSRange(location: location + span.location, length: span.length)
                    apply(item, to: shifted, in: text)
                }
            }
        }
    }

    /// After citations, so the icons never shift the offsets they are inserted at.
    static func insertIcons(into text: NSMutableAttributedString, font: NSFont) {
        var spots: [(location: Int, url: URL, kind: ChatFileItem.Kind)] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let url = value as? URL, url.isFileURL,
                let raw = text.attribute(kindKey, at: range.location, effectiveRange: nil) as? String,
                let kind = ChatFileItem.Kind(rawValue: raw)
            else { return }
            spots.append((range.location, url, kind))
        }
        for spot in spots.reversed() {
            guard let icon = icon(spot.kind, font: font, url: spot.url) else { continue }
            text.insert(icon, at: spot.location)
        }
    }

    static func symbol(_ kind: ChatFileItem.Kind) -> String {
        switch kind {
        case .folder: "folder"
        case .image: "photo"
        case .document: "doc"
        case .executable: "terminal"
        case .package: "app"
        }
    }

    private static func apply(_ item: ChatFileItem, to range: NSRange, in text: NSMutableAttributedString) {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return }
        text.addAttributes(
            [
                .link: URL(fileURLWithPath: item.path, isDirectory: item.kind == .folder),
                .toolTip: (item.path as NSString).abbreviatingWithTildeInPath,
                kindKey: item.kind.rawValue
            ], range: range)
    }

    /// Copies as nothing, as a formula copies as its source, so a copied path reads as written.
    private static func icon(_ kind: ChatFileItem.Kind, font: NSFont, url: URL) -> NSAttributedString? {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: (font.pointSize * 0.8).rounded(), weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Theme.Colors.accentInk]))
        guard
            let symbol = NSImage(systemSymbolName: symbol(kind), accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else { return nil }
        let gap = (font.pointSize * 0.25).rounded()
        let size = NSSize(width: ceil(symbol.size.width) + gap, height: ceil(symbol.size.height))
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0, y: ((font.capHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
        let icon = NSMutableAttributedString(attachment: attachment)
        icon.addAttributes(
            [
                .font: font, .link: url, .toolTip: (url.path as NSString).abbreviatingWithTildeInPath,
                ChatMarkdownRenderer.mathSource: ""
            ], range: NSRange(location: 0, length: icon.length))
        return icon
    }
}
