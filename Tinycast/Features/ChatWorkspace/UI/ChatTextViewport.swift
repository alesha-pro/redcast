import AppKit
import IOSurface

/// Fork: a reply's text drawn only where it shows; a tall reply's own backing cost 30 MB per view.
final class ChatTextViewport: NSView {
    /// Drawn past the visible edges, so a scroll meets text before the slice has to move.
    private static let overdraw: CGFloat = 200
    private weak var text: ChatSelectableTextView?
    private var scrolling: NotificationToken?
    private var showing: NotificationToken?

    init(text: ChatSelectableTextView) {
        self.text = text
        super.init(frame: .zero)
        // Placed by hand: a mask's constraint against a text view still unmeasured overflows.
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    /// A snapshot or drag image draws the text view itself, so the slice adds nothing there.
    override func draw(_ dirtyRect: NSRect) {}

    /// Drawn on the CPU straight into the surface the layer shows, so the slice exists only once.
    override func updateLayer() {
        // A window never shown, as a snapshot's, draws the text view itself through `draw(_:)`.
        guard let layer, window?.isVisible == true else { return }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((bounds.width * scale).rounded(.up))
        let height = Int((bounds.height * scale).rounded(.up))
        guard width > 0, height > 0, let surface = Self.surface(width: width, height: height) else {
            layer.contents = nil
            return
        }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard
            let context = CGContext(
                data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: surface.bytesPerRow, space: Self.colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: 0, y: -(bounds.height + frame.minY))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let slice = frame
        effectiveAppearance.performAsCurrentDrawingAppearance { text?.draw(slice) }
        NSGraphicsContext.restoreGraphicsState()
        layer.contentsScale = scale
        layer.contents = surface
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func surface(width: Int, height: Int) -> IOSurface? {
        let surface = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4,
            .pixelFormat: UInt32(0x4247_5241)  // 'BGRA'
        ])
        if let surface, let space = colorSpace.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, space)
        }
        return surface
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { layer?.contents = nil }
    }

    /// Follows the visible part of the text, and holds nothing while the text is off screen.
    func place() {
        guard let text else { return }
        let visible = text.visibleRect
        guard !visible.isEmpty else {
            if frame != .zero {
                frame = .zero
                layer?.contents = nil
            }
            return
        }
        if frame.width == text.bounds.width, frame.contains(visible) { return }
        let slice = visible.insetBy(dx: 0, dy: -Self.overdraw).intersection(text.bounds)
        frame = CGRect(x: 0, y: slice.minY, width: text.bounds.width, height: slice.height)
        needsDisplay = true
    }

    func invalidate(_ rect: NSRect) {
        let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY).intersection(bounds)
        if !local.isEmpty { setNeedsDisplay(local) }
    }

    /// A scroll moves the text without touching its frame, and a window shown later needs a draw.
    func watchWindow() {
        scrolling = nil
        showing = nil
        if let window = text?.window {
            let token = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
            showing = NotificationToken(token, center: .default)
        }
        guard let clip = text?.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        let token = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        scrolling = NotificationToken(token, center: .default)
    }
}

/// Fork: on screen the viewport draws the text; a backing as tall as a reply cost 30 MB.
extension ChatSelectableTextView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {}

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if newValue { chatViewport.needsDisplay = true }
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        chatViewport.invalidate(invalidRect)
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
        chatViewport.invalidate(rect)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        chatViewport.place()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        chatViewport.watchWindow()
        chatViewport.place()
    }
}
