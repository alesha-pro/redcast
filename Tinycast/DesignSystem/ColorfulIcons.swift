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

    /// `icon` from a view's `body`, which then repaints when the switch moves.
    @MainActor static func observedIcon(symbol: String, hue: RaycastHue?) -> EntryIcon {
        IconCache.observeStyle()
        return icon(symbol: symbol, hue: hue)
    }

    /// An `IconCache` tile's fill for a family while the switch is on; nil keeps upstream's grey.
    static func tint(_ category: GlyphCategory) -> SymbolTint? {
        isEnabled ? category.hue.symbolTint : nil
    }

    /// A glyph drawn bare, as a ⌘K row's: tinted on, the caller's neutral off.
    @MainActor static func glyphColor(_ hue: RaycastHue?, otherwise neutral: Color) -> Color {
        IconCache.observeStyle()
        guard isEnabled, let hue else { return neutral }
        return hue.color
    }
}

extension RaycastHue {
    var symbolTint: SymbolTint { SymbolTint(key: "raycast-" + rawValue, color: tileNSColor) }
}
