import AppKit
import SwiftUI

/// Fork: a code block's language as a small pill in its own hue, over the block's header strip.
@MainActor
enum ChatCodeBadge {
    static func style(_ label: NSTextField, language: String?) {
        let hue = CodeLanguageHue.hue(for: language)
        label.textColor = NSColor(hue.ink)
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = Theme.Radius.glyph * 2
        label.layer?.backgroundColor = hue.tileNSColor.withAlphaComponent(0.16).cgColor
        label.isHidden = (language ?? "").isEmpty
    }

    /// As wide as the name and a little padding, centred in the strip's height.
    static func frame(for label: NSTextField, in strip: CGRect) -> CGRect {
        let text = label.intrinsicContentSize
        let width = min(text.width + Theme.Spacing.md * 2, strip.width)
        let height = min(text.height + Theme.Spacing.xxs * 2, strip.height)
        return CGRect(x: strip.minX, y: strip.minY + (strip.height - height) / 2, width: width, height: height)
    }
}

/// Fork: a finished tool call's glyph, in the colour of what it did: web, files, terminal, MCP.
struct ChatToolGlyph: View {
    @Environment(\.metrics) private var metrics
    let use: ChatToolUse

    var body: some View {
        let kind = ChatToolKind.of(title: use.title, origin: use.origin)
        Image(systemName: kind.symbol)
            .font(metrics.typography.rowTrailing)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(kind.hue.color)
    }
}

extension View {
    /// Fork: the reader's own message on a wash of the accent, edged a step deeper.
    func chatBubble(isUser: Bool, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(shape.fill(isUser ? Theme.Colors.chatUserBubble : Color.clear))
            .overlay { if isUser { shape.strokeBorder(Theme.Colors.chatUserBubbleEdge) } }
    }
}
