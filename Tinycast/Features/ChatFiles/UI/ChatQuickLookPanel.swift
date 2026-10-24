import AppKit
import QuickLookUI

/// One preview at a time, over the chat it came from; it lives only while it is shown.
@MainActor
final class ChatQuickLookPanel: NSPanel {
    private static var shown: ChatQuickLookPanel?
    private static let size = NSSize(width: 720, height: 540)

    private let preview: QLPreviewView
    private let url: URL
    /// Over the palette it never takes the keyboard, since the palette hides once it loses it.
    private let takesKey: Bool
    private var parentClosing: NotificationToken?
    private var finished = false

    /// The same file again closes it, as Space does in Finder; another file replaces the preview.
    static func toggle(_ url: URL, over parent: NSWindow?) {
        if let shown, shown.url == url {
            shown.close()
            return
        }
        shown?.close()
        let panel = ChatQuickLookPanel(url, over: parent)
        shown = panel
        panel.present(over: parent)
    }

    private init(_ url: URL, over parent: NSWindow?) {
        self.url = url
        takesKey = !(parent is NSPanel)
        preview =
            QLPreviewView(frame: NSRect(origin: .zero, size: Self.size), style: .normal) ?? QLPreviewView()
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = !takesKey
        title = url.lastPathComponent
        representedURL = url
        preview.shouldCloseWithWindow = false
        preview.previewItem = url as NSURL
        contentView = preview
    }

    override var canBecomeKey: Bool { takesKey }

    private func present(over parent: NSWindow?) {
        if let parent {
            let frame = parent.frame
            setFrameOrigin(
                NSPoint(x: frame.midX - Self.size.width / 2, y: frame.midY - Self.size.height / 2))
            parent.addChildWindow(self, ordered: .above)
            parentClosing = NotificationToken(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: parent, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } },
                center: .default)
        } else {
            center()
        }
        if takesKey { makeKeyAndOrderFront(nil) } else { orderFront(nil) }
    }

    /// Space and Escape close it, as they close Finder's Quick Look.
    override func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == " " else { return super.keyDown(with: event) }
        close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func close() {
        super.close()
        finish()
    }

    /// The palette orders its children out with itself rather than closing them.
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        finish()
    }

    /// The preview holds its file open until it is closed, so it goes with the panel.
    private func finish() {
        guard !finished else { return }
        finished = true
        parent?.removeChildWindow(self)
        preview.close()
        parentClosing = nil
        if Self.shown === self { Self.shown = nil }
    }
}
