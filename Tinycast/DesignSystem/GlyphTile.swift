import SwiftUI

/// A glyph on its hue's rounded tile in white, Raycast's built-in command look, at any size.
struct GlyphTile: View {
    let symbol: String
    let hue: RaycastHue
    var size: CGFloat = Theme.Size.settingsRowIcon
    var isSelected = false

    var body: some View {
        IconCache.observeStyle()
        let colorful = ColorfulIcons.isEnabled
        let shape = RoundedRectangle(cornerRadius: size * Theme.Size.glyphTileCorner, style: .continuous)
        return SymbolImage(name: symbol, size: size * Theme.Size.glyphTileGlyph, monochrome: true)
            .foregroundStyle(colorful ? Color.white : Theme.Colors.textSecondary)
            .frame(width: size, height: size)
            .background(shape.fill(colorful ? hue.tileColor : Theme.Colors.controlSurface))
            .overlay {
                if isSelected { shape.strokeBorder(Theme.Colors.selectedTileEdge) }
            }
            .accessibilityHidden(true)
    }

    /// A menu item draws an image, not a view; the tile comes from `IconCache`.
    @MainActor static func menuImage(symbol: String, hue: RaycastHue) -> NSImage {
        IconCache.observeStyle()
        let tile = IconCache.symbolIcon(
            named: symbol, tint: ColorfulIcons.isEnabled ? hue.symbolTint : nil)
        let side = Theme.Size.menuItemImage
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            tile.draw(in: rect)
            return true
        }
    }
}

extension View {
    /// A bare glyph in its family's colour while the switch is on, `neutral` while it is off.
    func glyphTint(_ hue: RaycastHue?, otherwise neutral: Color = Theme.Colors.textSecondary) -> some View {
        modifier(GlyphTint(hue: hue, neutral: neutral))
    }
}

private struct GlyphTint: ViewModifier {
    let hue: RaycastHue?
    let neutral: Color

    func body(content: Content) -> some View {
        content.foregroundStyle(ColorfulIcons.glyphColor(hue, otherwise: neutral))
    }
}
