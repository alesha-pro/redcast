import SwiftUI

/// The chat's agent as it is now; a reply carries no agent of its own, so this heads the chat.
struct AgentChatBadge: Equatable {
    let name: String
    let symbol: String
    let hue: RaycastHue
    let directory: String

    init(_ agent: AgentProfile) {
        name = agent.name
        symbol = agent.symbol
        hue = agent.hue
        directory = agent.directory
    }
}

extension EnvironmentValues {
    /// Set by AI Chat's window for an agent chat; a plain chat and the palette leave it nil.
    @Entry var agentChatBadge: AgentChatBadge?
}

/// The agent's tile, name and folder above the transcript; the tile carries the colour.
struct AgentChatHeader: View {
    let badge: AgentChatBadge

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            GlyphTile(symbol: badge.symbol, hue: badge.hue, size: Theme.Size.chatSourceBadge)
            Text(verbatim: badge.name)
                .font(Theme.Typography.bar)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
            Text(verbatim: (badge.directory as NSString).abbreviatingWithTildeInPath)
                .font(Theme.Typography.bar)
                .foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
