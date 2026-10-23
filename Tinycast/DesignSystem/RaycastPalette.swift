import SwiftUI

/// Fork: how a `RaycastHue` paints; the values themselves live with the hue.
extension RaycastHue {
    /// A glyph or text in this hue: Raycast Dark's value on the dark surface, Light's on the light.
    var color: Color { Self.glyphColors[self] ?? .primary }

    /// Fixed sRGB in both appearances, as a tile rasterizes off-main and keeps white ink.
    var tileNSColor: NSColor { Self.rgb(tile) }

    var tileColor: Color { Color(nsColor: tileNSColor) }

    /// For AppKit surfaces that resolve once, such as a menu-bar menu's item image.
    func nsColor(isDark: Bool) -> NSColor { Self.rgb(isDark ? dark : light) }

    private static let glyphColors: [RaycastHue: Color] = Dictionary(
        uniqueKeysWithValues: allCases.map {
            ($0, Theme.Colors.adaptive(dark: rgb($0.dark), light: rgb($0.light)))
        })

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
