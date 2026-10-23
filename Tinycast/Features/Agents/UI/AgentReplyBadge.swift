import SwiftUI

/// What an agent chat's replies open with, so whose answer each one is reads at a glance.
struct AgentReplyBadge: Equatable {
    let name: String
    let symbol: String
    let hue: RaycastHue

    init(_ agent: AgentProfile) {
        name = agent.name
        symbol = agent.symbol
        hue = agent.hue
    }
}

extension EnvironmentValues {
    /// Set by AI Chat's window for an agent chat; a plain chat and the palette leave it nil.
    @Entry var agentReplyBadge: AgentReplyBadge?
}

/// The agent's tile and name above a reply; the tile carries the colour, the name stays legible.
struct AgentReplyBadgeView: View {
    let badge: AgentReplyBadge

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            GlyphTile(symbol: badge.symbol, hue: badge.hue, size: Theme.Size.chatSourceBadge)
            Text(verbatim: badge.name)
                .font(Theme.Typography.bar)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
