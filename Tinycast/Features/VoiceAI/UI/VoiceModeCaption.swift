import AppKit
import SwiftUI

/// The dictation mode, named in a chip above the capsule; built when shown, released when closed.
@MainActor
final class VoiceModeCaption {
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
                x: capsule.midX - size.width / 2, y: capsule.maxY + Theme.Spacing.md,
                width: size.width, height: size.height),
            display: true)
        // Never key: Tab, Return and Escape stay the capsule's.
        if !panel.isVisible {
            panel.fadeIn(duration: Theme.Duration.enter) { panel.orderFrontRegardless() }
        }
    }

    func close() {
        // The handler holds the panel until it is off screen, since nothing else does once dropped.
        let closing = panel
        closing?.fadeOut(duration: Theme.Duration.exit) { _ = closing }
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
                .contentTransition(.opacity)
            Text(verbatim: "⇥")
                .foregroundStyle(.secondary)
        }
        .animation(Theme.Motion.swap, value: name)
        .font(Theme.Typography.bar)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .fixedSize()
        .glassSurface(.chip, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Dictation mode: \(name)"))
        .motionScope()
    }
}
