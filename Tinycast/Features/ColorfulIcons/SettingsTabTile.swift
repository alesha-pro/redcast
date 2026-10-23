import SwiftUI

/// A Settings tab's tile: its hue under a white glyph, or upstream's tinted glyph while off.
struct SettingsTabTile: View {
    let tab: SettingsTab
    var tint = Color.accentColor
    var size = Theme.Size.settingsSidebarGlyph + Theme.Spacing.xs * 2
    var isSelected = false

    var body: some View {
        IconCache.observeStyle()
        return Group {
            if ColorfulIcons.isEnabled {
                GlyphTile(symbol: tab.systemImage, hue: tab.hue, size: size, isSelected: isSelected)
            } else {
                SettingsTabIcon(systemImage: tab.systemImage, tint: tint, size: size)
            }
        }
    }
}
