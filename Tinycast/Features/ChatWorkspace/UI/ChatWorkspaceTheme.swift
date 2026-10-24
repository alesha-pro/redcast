import SwiftUI

/// Fork: AI Chat's colour pass, as tokens over the vermilion brand rather than literals in views.
extension Theme.Colors {
    /// The user's bubble: a wash of the accent, faint enough that body text keeps its contrast.
    static let chatUserBubble = adaptive(
        dark: vermilion.withAlphaComponent(0.20), light: vermilion.withAlphaComponent(0.09))
    static let chatUserBubbleEdge = adaptive(
        dark: vermilion.withAlphaComponent(0.32), light: vermilion.withAlphaComponent(0.18))
    /// The open chat's row in the sidebar, the selection's own wash.
    static let chatSelectedRow = adaptive(
        dark: vermilion.withAlphaComponent(0.26), light: vermilion.withAlphaComponent(0.14))
    /// A folder or section under a dragged chat.
    static let chatDropTarget = adaptive(
        dark: vermilion.withAlphaComponent(0.30), light: vermilion.withAlphaComponent(0.16))
    /// A recalled question being edited, outlined in the accent.
    static let chatEditingEdge = adaptive(
        dark: vermilion.withAlphaComponent(0.85), light: vermilion.withAlphaComponent(0.75))
    /// The settings sidebar's cards, a step off its own surface.
    static let chatSettingsCard = ramp(dark: 0.05, light: 0.035)
}

extension RaycastHue {
    /// A coloured header's or label's text, past 4.5:1 in both appearances (`ChatPalette`).
    var ink: Color { Self.inks[self] ?? .primary }

    private static let inks = Dictionary(
        uniqueKeysWithValues: allCases.map { hue in
            (hue, Theme.Colors.adaptive(
                dark: hex(ChatPalette.darkInk(hue)), light: hex(ChatPalette.lightInk(hue))))
        })

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// A hue's wash behind a badge's ink: a chip, a code block's language, a tool's glyph.
    var wash: Color { Self.washes[self] ?? .clear }

    private static let washes = Dictionary(
        uniqueKeysWithValues: allCases.map { hue in
            (hue, Theme.Colors.adaptive(
                dark: hue.tileNSColor.withAlphaComponent(0.22), light: hue.tileNSColor.withAlphaComponent(0.12)))
        })
}

/// Fork: the window's sizes for folders, the settings sidebar and the slimmer composer.
extension Theme.Size {
    static let chatFolderTile: CGFloat = 18
    static let chatHeaderGlyph: CGFloat = 11
    /// A chat filed in a folder sits in under it, behind a bar in the folder's colour.
    static let chatFolderIndent: CGFloat = 14
    static let chatFolderBar: CGFloat = 2
    static let chatSettingsMinimum: CGFloat = 260
    static let chatSettingsMaximum: CGFloat = 380
    static let chatSwatch: CGFloat = 18
    static let chatIconCell: CGFloat = 26
    static let chatInstructionsHeight: CGFloat = 96
    static let chatShortcutBadge: CGFloat = 18
    static let chatModelChipMaxWidth: CGFloat = 220
}
