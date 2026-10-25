import AppKit
import SwiftUI

/// Fork: AppKit's own tooltip over a view; SwiftUI's `.help` cost 130 environment nodes each.
struct ChatToolTip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TipView { TipView() }

    func updateNSView(_ view: TipView, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }

    /// A tooltip needs only the pointer over its bounds, so clicks pass through to the view below.
    final class TipView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// The tooltip `.help` shows, drawn by AppKit; the label stays the view's own accessibility.
    func chatToolTip(_ text: String) -> some View {
        overlay(ChatToolTip(text: text))
    }
}
