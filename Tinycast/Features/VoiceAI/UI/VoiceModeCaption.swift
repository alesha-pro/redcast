import AppKit
import SwiftUI

/// The dictation mode, named in a chip above the capsule; built when shown, released when closed.
@MainActor
final class VoiceModeCaption {
    private static let gap: CGFloat = 8

    private var panel: NSPanel?
    private var hosting: NSHostingView<VoiceModeChip>?

    func show(_ name: String, above capsule: NSRect) {
        let hosting = hosting ?? NSHostingView(rootView: VoiceModeChip(name: name))
        hosting.rootView = VoiceModeChip(name: name)
        self.hosting = hosting
        let size = hosting.fittingSize
        let panel = panel ?? Self.makePanel(content: hosting)
        self.panel = panel
        panel.setFrame(
            NSRect(
                x: capsule.midX - size.width / 2, y: capsule.maxY + Self.gap,
                width: size.width, height: size.height),
            display: true)
        // Never key: Tab, Return and Escape stay the capsule's.
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }

    private static func makePanel(content: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private struct VoiceModeChip: View {
    let name: String

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(verbatim: name)
                .lineLimit(1)
            Text(verbatim: "⇥")
                .foregroundStyle(.secondary)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Dictation mode: \(name)"))
        .motionScope()
    }
}
