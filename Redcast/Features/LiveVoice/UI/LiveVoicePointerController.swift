import AppKit
import SwiftUI

/// A pointer that flies from the cursor to a place on screen, names it, and is gone again.
@MainActor
final class LiveVoicePointerController {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    private static let flight: CFTimeInterval = 0.45
    private static let linger: Duration = .seconds(3.5)
    private static let fade: TimeInterval = 0.3
    private static let arrow = CGSize(width: 22, height: 26)
    private static let edgeMargin: CGFloat = 12

    /// `point` is a global AppKit point, as `LiveVoiceFrame.point` returns it.
    func show(at point: CGPoint, label: String) {
        guard let screen = Self.screen(for: point) else { return }
        dismiss()
        let panel = Self.overlay(on: screen)
        guard let root = panel.contentView?.layer else { return }
        let scale = screen.backingScaleFactor
        root.contentsScale = scale

        let target = CGPoint(
            x: min(max(point.x - screen.frame.minX, 0), screen.frame.width),
            y: min(max(point.y - screen.frame.minY, 0), screen.frame.height))
        let mouse = NSEvent.mouseLocation
        let start =
            Self.contains(mouse, in: screen.frame)
            ? CGPoint(x: mouse.x - screen.frame.minX, y: mouse.y - screen.frame.minY)
            : CGPoint(x: screen.frame.width / 2, y: screen.frame.height / 2)

        let palette = Self.resolvedColors(for: panel.effectiveAppearance)
        let animates = Motion.isEnabled

        let arrow = Self.arrowLayer(palette: palette, scale: scale)
        arrow.position = target
        root.addSublayer(arrow)
        if animates { arrow.add(Self.flightAnimation(from: start, to: target), forKey: "flight") }

        let ring = Self.ringLayer(palette: palette, scale: scale)
        ring.position = target
        root.addSublayer(ring)
        if animates { ring.add(Self.pulseAnimation(), forKey: "pulse") }

        if !label.isEmpty {
            let caption = Self.captionLayer(label, palette: palette, scale: scale)
            caption.position = Self.captionPosition(
                for: caption.bounds.size, near: target, in: screen.frame.size)
            root.addSublayer(caption)
            if animates {
                caption.opacity = 0
                let appear = CABasicAnimation(keyPath: "opacity")
                appear.fromValue = 0
                appear.toValue = 1
                appear.beginTime = CACurrentMediaTime() + Self.flight
                appear.duration = 0.15
                appear.fillMode = .forwards
                appear.isRemovedOnCompletion = false
                caption.add(appear, forKey: "appear")
            }
        }

        panel.orderFrontRegardless()
        self.panel = panel
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            let duration = Motion.duration(Self.fade)
            if duration > 0 {
                await NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration
                    panel.animator().alphaValue = 0
                }
            }
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel?.contentView?.layer?.removeAllAnimations()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    /// Inclusive boundary match so coordinates at `maxX` or `maxY` still hit their display.
    private static func screen(for point: CGPoint) -> NSScreen? {
        if let exact = NSScreen.screens.first(where: { contains(point, in: $0.frame) }) {
            return exact
        }
        return NSScreen.screens.min { lhs, rhs in
            squaredDistance(from: point, to: lhs.frame) < squaredDistance(from: point, to: rhs.frame)
        }
    }

    private static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }

    private struct Palette {
        let accent: CGColor
        let ink: NSColor
        let inkCG: CGColor
        let shadow: CGColor
    }

    private static func resolvedColors(for appearance: NSAppearance) -> Palette {
        var accent = NSColor.systemRed.cgColor
        var ink = NSColor.white
        var shadow = NSColor.black.cgColor
        appearance.performAsCurrentDrawingAppearance {
            accent = NSColor(Theme.Colors.accent).cgColor
            ink = NSColor(Theme.Colors.composerSendInk)
            shadow = NSColor(Theme.Colors.roomCardShadow).cgColor
        }
        return Palette(accent: accent, ink: ink, inkCG: ink.cgColor, shadow: shadow)
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
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        // Explicitly place after creation so secondary displays with negative origins never clamp.
        panel.setFrame(screen.frame, display: true)
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        panel.contentView = view
        return panel
    }

    private static func arrowLayer(palette: Palette, scale: CGFloat) -> CAShapeLayer {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: arrow.width, y: -arrow.height * 0.62))
        path.addLine(to: CGPoint(x: arrow.width * 0.42, y: -arrow.height * 0.62))
        path.addLine(to: CGPoint(x: 0, y: -arrow.height))
        path.closeSubpath()
        let layer = CAShapeLayer()
        layer.contentsScale = scale
        layer.path = path
        layer.fillColor = palette.accent
        layer.strokeColor = palette.inkCG
        layer.lineWidth = 1.5
        layer.lineJoin = .round
        layer.shadowColor = palette.shadow
        layer.shadowOpacity = 1
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: -2)
        return layer
    }

    private static func ringLayer(palette: Palette, scale: CGFloat) -> CAShapeLayer {
        let radius: CGFloat = 16
        let layer = CAShapeLayer()
        layer.contentsScale = scale
        layer.path = CGPath(
            ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        layer.fillColor = nil
        layer.strokeColor = palette.accent
        layer.lineWidth = 2.5
        layer.opacity = 0
        return layer
    }

    private static func captionLayer(_ label: String, palette: Palette, scale: CGFloat) -> CALayer {
        let base = NSFont.preferredFont(forTextStyle: .callout)
        let font = NSFont.systemFont(ofSize: base.pointSize, weight: .semibold)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: palette.ink])
        let size = text.size()
        let padding = CGSize(width: Theme.Spacing.lg, height: Theme.Spacing.xs + 1)
        let background = CALayer()
        background.contentsScale = scale
        background.bounds = CGRect(
            x: 0, y: 0, width: ceil(size.width) + padding.width * 2,
            height: ceil(size.height) + padding.height * 2)
        background.backgroundColor = palette.accent
        background.cornerRadius = background.bounds.height / 2
        background.shadowColor = palette.shadow
        background.shadowOpacity = 1
        background.shadowRadius = 8
        background.shadowOffset = CGSize(width: 0, height: -3)
        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.contentsScale = scale
        textLayer.frame = CGRect(
            x: padding.width, y: padding.height, width: ceil(size.width), height: ceil(size.height))
        background.addSublayer(textLayer)
        return background
    }

    /// Below and to the right of the arrow, flipped and clamped so it never leaves the display.
    private static func captionPosition(for size: CGSize, near target: CGPoint, in screen: CGSize) -> CGPoint {
        var x = target.x + arrow.width + size.width / 2
        var y = target.y - arrow.height - size.height / 2
        if x + size.width / 2 > screen.width - edgeMargin { x = target.x - arrow.width - size.width / 2 }
        if y - size.height / 2 < edgeMargin { y = target.y + arrow.height / 2 + size.height / 2 }
        let minX = size.width / 2 + edgeMargin
        let maxX = max(minX, screen.width - size.width / 2 - edgeMargin)
        let minY = size.height / 2 + edgeMargin
        let maxY = max(minY, screen.height - size.height / 2 - edgeMargin)
        return CGPoint(x: min(max(x, minX), maxX), y: min(max(y, minY), maxY))
    }

    private static func flightAnimation(from start: CGPoint, to end: CGPoint) -> CAAnimation {
        let lift = min(hypot(end.x - start.x, end.y - start.y) * 0.25, 160)
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(
            to: end, control: CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + lift))
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
