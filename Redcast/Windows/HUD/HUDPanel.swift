import AppKit

/// Borderless panel for a transient readout: never key, always above the palette.
final class HUDPanel: NSPanel {
    init(acceptsMouseEvents: Bool = false) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        // The window server's shadow is a HUD's elevation; its glass draws no shadow of its own.
        hasShadow = true
        level = .palette
        ignoresMouseEvents = !acceptsMouseEvents
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
