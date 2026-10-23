import SwiftUI

extension AppEntry {
    /// From the kind, then the command catalog; apps, files and extensions keep their own artwork.
    var glyphCategory: GlyphCategory? {
        switch kind {
        case .command: CommandID(rawValue: id).map(GlyphCategory.init)
        case .quickAction, .agent: .ai
        case .customCommand: .scripts
        case .snippet: .snippets
        case .systemAction: .system
        case .windowCommand, .windowLayout, .windowRoom: .windows
        case .quicklink: .quicklinks
        case .meeting: .calendar
        case .application, .systemSettings, .appleShortcut, .extensionCommand: nil
        }
    }

    /// `defaultIcon`'s symbol on its family's tile; an agent's own colour rides `iconOverride`.
    func colorfulIcon(symbol: String) -> EntryIcon {
        ColorfulIcons.icon(symbol: symbol, hue: glyphCategory?.hue)
    }
}

extension AgentProfile {
    /// The colour it was given, else one derived from its id that holds across launches.
    var hue: RaycastHue { RaycastHue.agent(named: color, id: id) }
}

extension AgentSource {
    /// The brand mark a session row and the Agents menu draw on the source's tile.
    var tileSymbol: String {
        switch self {
        case .claude: AIBrand.claude.assetName
        case .codex: AIBrand.openAI.assetName
        case .gemini: AIBrand.gemini.assetName
        case .openCode: AIBrand.openCode.assetName
        case .tinycast: "bubble.left"
        }
    }

    /// Each CLI in its maker's colour; Tinycast's own chats in AI's red.
    var hue: RaycastHue {
        switch self {
        case .claude: .orange
        case .codex: .green
        case .gemini: .blue
        case .openCode: .purple
        case .tinycast: .red
        }
    }
}

extension AppCore {
    /// An agent's row carries its tile in the entry itself, so the switch republishes them.
    func applyColorfulIcons() {
        ColorfulIcons.setEnabled(settings.colorfulIcons)
        agentCoordinator.publishLauncherRows()
    }
}

extension SettingsTab {
    /// The sidebar's families match the launcher's, so a feature wears one colour everywhere.
    var hue: RaycastHue {
        switch self {
        case .general, .systemSettings, .fallbacks, .about: .gray
        case .permissions, .applications, .fileSearch, .navigation, .dictation: .blue
        case .systemActions, .backup: .green
        case .commands, .clipboard, .snippets: .orange
        case .quicklinks, .extensions: .magenta
        case .appleShortcuts, .windowManagement: .purple
        case .notes, .calendar, .emoji: .yellow
        case .ai, .quickActions: .red
        }
    }
}

/// A Settings tab's tile: its hue under a white glyph, or upstream's tinted glyph while off.
struct SettingsTabTile: View {
    let tab: SettingsTab
    var tint = Color.accentColor
    var size = Theme.Size.settingsSidebarGlyph + Theme.Spacing.xs * 2

    var body: some View {
        IconCache.observeStyle()
        return Group {
            if ColorfulIcons.isEnabled {
                GlyphTile(symbol: tab.systemImage, hue: tab.hue, size: size)
            } else {
                SettingsTabIcon(systemImage: tab.systemImage, tint: tint, size: size)
            }
        }
    }
}
