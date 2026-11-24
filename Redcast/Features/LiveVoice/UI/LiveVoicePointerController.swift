import AppKit

/// A pointer that flies from the cursor to a place on screen, names it, and is gone again.
@MainActor
final class LiveVoicePointerController {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    private static let flight: CFTimeInterval = 0.45
    private static let linger: Duration = .seconds(3.5)
    private static let fade: TimeInterval = 0.3
    private static let arrow = CGSize(width: 22, height: 26)

    /// `point` is a global AppKit point, as `LiveVoiceFrame.point` returns it.
    func show(at point: CGPoint, label: String) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        dismiss()
        let panel = Self.overlay(on: screen)
        guard let root = panel.contentView?.layer else { return }
        let target = CGPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY)
        let mouse = NSEvent.mouseLocation
        let start =
            screen.frame.contains(mouse)
            ? CGPoint(x: mouse.x - screen.frame.minX, y: mouse.y - screen.frame.minY)
            : CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2)

        let arrow = Self.arrowLayer()
        arrow.position = target
        root.addSublayer(arrow)
        arrow.add(Self.flightAnimation(from: start, to: target), forKey: "flight")

        let ring = Self.ringLayer()
        ring.position = target
        root.addSublayer(ring)
        ring.add(Self.pulseAnimation(), forKey: "pulse")

        if !label.isEmpty {
            let caption = Self.captionLayer(label, scale: screen.backingScaleFactor)
            caption.position = Self.captionPosition(for: caption.bounds.size, near: target, in: screen.frame.size)
            caption.opacity = 0
            root.addSublayer(caption)
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.beginTime = CACurrentMediaTime() + Self.flight
            appear.duration = 0.15
            appear.fillMode = .forwards
            appear.isRemovedOnCompletion = false
            caption.add(appear, forKey: "appear")
        }

        panel.orderFrontRegardless()
        self.panel = panel
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fade
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static func overlay(on screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        panel.contentView = view
        return panel
    }

    private static func arrowLayer() -> CAShapeLayer {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: arrow.width, y: -arrow.height * 0.62))
        path.addLine(to: CGPoint(x: arrow.width * 0.42, y: -arrow.height * 0.62))
        path.addLine(to: CGPoint(x: 0, y: -arrow.height))
        path.closeSubpath()
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = NSColor.controlAccentColor.cgColor
        layer.strokeColor = NSColor.white.cgColor
        layer.lineWidth = 1.5
        layer.lineJoin = .round
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -2)
        return layer
    }

    private static func ringLayer() -> CAShapeLayer {
        let radius: CGFloat = 16
        let layer = CAShapeLayer()
        layer.path = CGPath(
            ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        layer.fillColor = nil
        layer.strokeColor = NSColor.controlAccentColor.cgColor
        layer.lineWidth = 2.5
        layer.opacity = 0
        return layer
    }

    private static func captionLayer(_ label: String, scale: CGFloat) -> CALayer {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = text.size()
        let padding = CGSize(width: 10, height: 5)
        let background = CALayer()
        background.bounds = CGRect(
            x: 0, y: 0, width: ceil(size.width) + padding.width * 2, height: ceil(size.height) + padding.height * 2)
        background.backgroundColor = NSColor.controlAccentColor.cgColor
        background.cornerRadius = background.bounds.height / 2
        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.contentsScale = scale
        textLayer.frame = CGRect(x: padding.width, y: padding.height, width: ceil(size.width), height: ceil(size.height))
        background.addSublayer(textLayer)
        return background
    }

    /// Below and to the right of the arrow, flipped wherever that would leave the screen.
    private static func captionPosition(for size: CGSize, near target: CGPoint, in screen: CGSize) -> CGPoint {
        var x = target.x + arrow.width + size.width / 2
        var y = target.y - arrow.height - size.height / 2
        if x + size.width / 2 > screen.width { x = target.x - arrow.width - size.width / 2 }
        if y - size.height / 2 < 0 { y = target.y + arrow.height / 2 + size.height / 2 }
        return CGPoint(x: x, y: y)
    }

    private static func flightAnimation(from start: CGPoint, to end: CGPoint) -> CAAnimation {
        let lift = min(hypot(end.x - start.x, end.y - start.y) * 0.25, 160)
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + lift))
        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.path = path
        animation.duration = flight
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

    private static func pulseAnimation() -> CAAnimation {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.8
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.9
        opacity.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.beginTime = CACurrentMediaTime() + flight
        group.duration = 0.9
        group.repeatCount = 3
        return group
    }
}
