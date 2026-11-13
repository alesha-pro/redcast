import SwiftUI

/// AppKit's glass as a window backdrop. Non-interactive: `effectIsInteractive` is macOS 27 only.
struct GlassEffectView: NSViewRepresentable {
    /// Zero leaves the glass square, for a caller whose own clip is the only corner.
    var cornerRadius: CGFloat = 0
    var tint: Color?
    var style: NSGlassEffectView.Style = .regular

    final class Coordinator {
        var tint: Color.Resolved?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        apply(to: view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        apply(to: nsView, context: context)
    }

    /// Compared first, so an update that changed nothing never invalidates the glass.
    private func apply(to view: NSGlassEffectView, context: Context) {
        if view.cornerRadius != cornerRadius { view.cornerRadius = cornerRadius }
        if view.style != style { view.style = style }
        // Resolved here: the view copies its tint, so a dynamic colour may never re-resolve.
        let resolved = tint?.resolve(in: context.environment)
        guard resolved != context.coordinator.tint else { return }
        context.coordinator.tint = resolved
        view.tintColor = resolved.map {
            NSColor(
                srgbRed: CGFloat($0.red), green: CGFloat($0.green), blue: CGFloat($0.blue),
                alpha: CGFloat($0.opacity))
        }
    }
}
