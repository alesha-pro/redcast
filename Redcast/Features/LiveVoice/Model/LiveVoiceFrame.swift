import CoreGraphics
import Foundation

/// One screenshot's geometry: its pixels, and the display it shows in AppKit's global points.
struct LiveVoiceFrame: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let display: CGRect

    /// A place in the screenshot, origin top left, as a global AppKit point, origin bottom left.
    func point(fraction: LiveVoicePoint) -> CGPoint? {
        guard (0...1).contains(fraction.x), (0...1).contains(fraction.y), !display.isEmpty else { return nil }
        return CGPoint(
            x: display.minX + fraction.x * display.width, y: display.maxY - fraction.y * display.height)
    }

    /// The size a capture is scaled to, keeping its shape, so its longest edge fits `maxEdge`.
    static func fitted(width: Int, height: Int, maxEdge: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > maxEdge, longest > 0 else { return (width, height) }
        let scale = Double(maxEdge) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }
}
