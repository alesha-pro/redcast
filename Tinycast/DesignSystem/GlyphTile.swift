import SwiftUI
import Synchronization

/// Fork: General › Appearance › Colourful Icons, readable off-main as entry icons are.
enum ColorfulIcons {
    private static let enabled = Atomic(true)

    static var isEnabled: Bool { enabled.load(ordering: .relaxed) }

    /// A change re-keys every icon through `IconCache`, so rows, tiles and menus repaint alone.
    @MainActor static func setEnabled(_ isOn: Bool) {
        guard enabled.exchange(isOn, ordering: .relaxed) != isOn else { return }
        IconCache.invalidateStyled()
    }

    /// A launcher row's glyph: its family's tile while the switch is on, upstream's grey one off.
    static func icon(symbol: String, hue: RaycastHue?) -> EntryIcon {
        guard isEnabled, let hue else { return .symbol(symbol) }
        return .tintedSymbol(name: symbol, tint: hue.symbolTint)
    }

    /// An `IconCache` tile's fill for a family while the switch is on; nil keeps upstream's grey.
    static func tint(_ category: GlyphCategory) -> SymbolTint? {
        isEnabled ? category.hue.symbolTint : nil
    }

    /// A glyph drawn bare, as a ⌘K row's or the composer's: tinted on, the caller's grey off.
    @MainActor static func glyphColor(_ hue: RaycastHue?, otherwise neutral: Color) -> Color {
        IconCache.observeStyle()
        guard isEnabled, let hue else { return neutral }
        return hue.color
    }
}

extension RaycastHue {
    var symbolTint: SymbolTint { SymbolTint(key: "raycast-" + rawValue, color: tileNSColor) }
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

/// A glyph on its hue's rounded tile in white, Raycast's built-in command look, at any size.
struct GlyphTile: View {
    let symbol: String
    let hue: RaycastHue
    var size: CGFloat = Theme.Size.settingsRowIcon
    /// Off, the tile falls back to the launcher's grey one rather than vanishing.
    var followsSwitch = true

    var body: some View {
        IconCache.observeStyle()
        let colorful = !followsSwitch || ColorfulIcons.isEnabled
        return SymbolImage(name: symbol, size: size * Self.glyphRatio, monochrome: true)
            .foregroundStyle(colorful ? Color.white : Theme.Colors.textSecondary)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * Self.cornerRatio, style: .continuous)
                    .fill(colorful ? hue.tileColor : Theme.Colors.controlSurface))
            .accessibilityHidden(true)
    }

    /// The launcher tile's own proportions: a 21-point glyph and 9-point corners on a 40-point tile.
    private static let glyphRatio: CGFloat = 0.55
    private static let cornerRatio: CGFloat = 0.225

    /// What AppKit gives a symbol in a menu row, so a tile there sits where a glyph would.
    static let menuItemSide: CGFloat = 16

    /// A menu-bar or SwiftUI `Menu` item draws an image, not a view; the tile comes from `IconCache`.
    @MainActor static func menuImage(
        symbol: String, hue: RaycastHue, side: CGFloat = menuItemSide
    ) -> NSImage {
        let tile = IconCache.symbolIcon(
            named: symbol, tint: ColorfulIcons.isEnabled ? hue.symbolTint : nil)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            tile.draw(in: rect)
            return true
        }
        return image
    }
}
