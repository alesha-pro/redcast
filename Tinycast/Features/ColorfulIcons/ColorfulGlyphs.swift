import SwiftUI

extension AppEntry {
    /// From the kind, then the command catalog; apps, files and extensions keep their own artwork.
    var glyphCategory: GlyphCategory? {
        switch kind {
        case .command: CommandID(rawValue: id).flatMap(GlyphCategory.of)
        case .quickAction, .agent: .ai
        case .customCommand: .scripts
        case .snippet: .snippets
        case .systemAction: .system
        case .windowCommand, .windowLayout, .windowRoom: .windows
        case .quicklink: .quicklinks
        case .meeting: .calendar
        default: nil
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

extension PopoverMenuIcon {
    /// A model's mark in its maker's colour, the one its CLI's sessions wear; nil for any other.
    var brandHue: RaycastHue? {
        guard case .asset(let name) = self else { return nil }
        return AgentSource.allCases.first { $0.tileSymbol == name }?.hue
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
    /// Launcher families, so a feature wears one colour; magenta only parts two like neighbours.
    var hue: RaycastHue { Self.hues[self] ?? .gray }

    /// A pane upstream adds since is grey until it is given a family.
    private static let hues: [SettingsTab: RaycastHue] = {
        let families: [RaycastHue: [SettingsTab]] = [
            .blue: [.applications, .fileSearch, .navigation, .dictation, .shortcuts],
            .green: [.permissions, .systemActions, .backup],
            .orange: [.commands, .clipboard, .snippets],
            .purple: [.quicklinks, .windowManagement],
            .magenta: [.appleShortcuts],
            .yellow: [.notes, .calendar, .emoji],
            .red: [.ai, .quickActions, .extensions]
        ]
        return Dictionary(uniqueKeysWithValues: families.flatMap { hue, tabs in tabs.map { ($0, hue) } })
    }()
}
