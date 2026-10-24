import SwiftUI

/// Fork: the composer's one settings control: the chat's agent and model, opening the settings.
struct ChatModelChip: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let chat: AIChatState

    var body: some View {
        if let summary = workspace.settingsSource?.modelSummary(for: chat) {
            ChatModelChipLabel(summary: summary) { workspace.toggleSettingsSidebar?() }
        }
    }
}

/// The chip itself, from values alone, so the snapshot harness draws the same one.
struct ChatModelChipLabel: View {
    let summary: ChatModelSummary
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if let agent = summary.agent {
                    ChatFolderTile(symbol: agent.symbol, hue: agent.hue, size: Theme.Size.aiChatComposerGlyph)
                }
                if let icon = summary.icon {
                    ChatSettingsIconView(icon: icon, side: Theme.Size.aiChatComposerGlyph - 2)
                }
                Text(verbatim: summary.model)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: Theme.Size.aiChatComposerControl)
            .frame(maxWidth: Theme.Size.chatModelChipMaxWidth)
            .background(
                Capsule().fill(hovered ? Theme.Colors.controlHover : Theme.Colors.controlSurface))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: Theme.Duration.hover), value: hovered)
        .help("Chat Settings  ⇧⌘I")
        .accessibilityLabel(Text(verbatim: summary.model))
        .accessibilityHint("Shows or hides the chat's settings")
    }
}
