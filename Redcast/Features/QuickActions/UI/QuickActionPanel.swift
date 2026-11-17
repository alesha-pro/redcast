import AppKit
import Carbon.HIToolbox

/// Keys go through `sendEvent`, so ↵, ⌘C, ⌘J and Esc need no focused subview to reach the panel.
final class QuickActionPanel: NSPanel, AnimatedPanel {
    enum Key {
        case replace
        case copy
        case continueInChat
        case cancel
    }

    var onKey: ((Key) -> Void)?

    init(content: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: content.frame.size),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Above the palette, below a dialog: a failure report must still land on top of it.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        followMotion()
        isReleasedWhenClosed = false
        isRestorable = false
        contentView = content
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, let onKey else {
            super.sendEvent(event)
            return
        }
        // The command chords first: the modifier is what separates them from the plain keys.
        if event.modifierFlags.contains(.command) {
            switch Int(event.keyCode) {
            case kVK_ANSI_C: onKey(.copy)
            case kVK_ANSI_J: onKey(.continueInChat)
            default: super.sendEvent(event)
            }
            return
        }
        switch Int(event.keyCode) {
        case kVK_Escape:
            onKey(.cancel)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            onKey(.replace)
        default:
            super.sendEvent(event)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
