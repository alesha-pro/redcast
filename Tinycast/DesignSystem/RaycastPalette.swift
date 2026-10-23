import SwiftUI

/// Fork: how a `RaycastHue` paints; the values themselves live with the hue.
extension RaycastHue {
    /// Tinycast's own glyph: Raycast Dark's value on the dark surface, the tile's on the light.
    var color: Color { Self.glyphColors[self] ?? .primary }

    /// Raycast's API value in each appearance, so an extension's `raycast-*` paints as in Raycast.
    var apiColor: Color { Self.apiColors[self] ?? .primary }

    /// Fixed sRGB in both appearances, as a tile rasterizes off-main and keeps white ink.
    var tileNSColor: NSColor { Self.rgb(tile) }

    var tileColor: Color { Color(nsColor: tileNSColor) }

    /// Merged over `ExtensionImage`'s own names; grey is no `raycast-*` colour.
    static let extensionPalette: [String: Color] = Dictionary(
        uniqueKeysWithValues: allCases.filter { $0 != .gray }.map { ("raycast-" + $0.rawValue, $0.apiColor) })

    private static let glyphColors = paint { Theme.Colors.adaptive(dark: rgb($0.dark), light: rgb($0.tile)) }
    private static let apiColors = paint { Theme.Colors.adaptive(dark: rgb($0.dark), light: rgb($0.light)) }

    /// Built once, so a colour compares equal to itself and no view re-creates a dynamic one.
    private static func paint(_ color: (RaycastHue) -> Color) -> [RaycastHue: Color] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, color($0)) })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Fork: `GlyphTile` at `IconCache`'s tile proportions: a 21-point glyph, 9-point corners on 40.
extension Theme.Size {
    static let glyphTileGlyph: CGFloat = 21.0 / 40
    static let glyphTileCorner: CGFloat = 9.0 / 40
    /// The image AppKit gives a menu row, so a tile there sits where a symbol would.
    static let menuItemImage: CGFloat = 16
}

extension Theme.Colors {
    /// Fork: a primary button's label on its solid accent, white in both appearances.
    static let primaryActionInk = Color.white
    /// Fork: a selected Settings row is the accent, which a red or orange tile would melt into.
    static let selectedTileEdge = adaptive(dark: .srgbInk(1, alpha: 0.9), light: .srgbInk(1, alpha: 0.9))
}
