import SwiftUI

/// A Settings tab's tile, on its hue while Colourful Icons is on and on grey while it is off.
struct SettingsTabTile: View {
    let tab: SettingsTab
    var size = Theme.Size.settingsSidebarTile

    var body: some View {
        GlyphTile(symbol: tab.systemImage, hue: tab.hue, size: size)
    }
}
