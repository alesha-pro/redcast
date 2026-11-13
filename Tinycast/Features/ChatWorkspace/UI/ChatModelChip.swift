import AppKit
import SwiftUI

/// Fork: the composer's one settings control: the chat's agent and model, opening the model menu.
struct ChatModelChip: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let chat: AIChatState
    @State private var anchor = ChatMenuAnchor()

    var body: some View {
        if let summary = workspace.settingsSource?.modelSummary(for: chat) {
            ChatModelChipLabel(summary: summary, action: showMenu)
                .background(ChatMenuAnchorView(anchor: anchor))
        }
    }

    /// Built on the click, so a streaming reply never rebuilds a menu nobody has opened.
    private func showMenu() {
        guard let source = workspace.settingsSource, let view = anchor.view else { return }
        let menu = ChatModelNSMenu.build(source.settingsState(for: chat).pickers, workspace: workspace)
        // The chosen model lands over the chip, as a pop-up button opens on its own value.
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: .zero, in: view)
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
                if let access = summary.access {
                    ChatSettingsIconView(icon: access.icon, side: Theme.Size.aiChatComposerGlyph - 4)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.Typography.disclosure)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: Theme.Size.aiChatComposerControl)
            .frame(maxWidth: Theme.Size.chatModelChipMaxWidth)
            .contentShape(Capsule())
        }
        .buttonStyle(ChatModelChipStyle(hovered: hovered))
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
        .help("Switch this chat's model")
        .accessibilityLabel(Text(verbatim: summary.model))
        .accessibilityHint("Switch this chat's model")
    }
}

/// Matte, so it answers a press with a fill of its own: rest, hover, then held.
private struct ChatModelChipStyle: ButtonStyle {
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(fill(pressed: configuration.isPressed)))
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }

    private func fill(pressed: Bool) -> Color {
        if pressed { return Theme.Colors.controlPressed }
        return hovered ? Theme.Colors.controlHover : Theme.Colors.controlSurface
    }
}

/// The AppKit view a menu pops up from; held weakly, so it goes with the chip.
@MainActor
final class ChatMenuAnchor {
    weak var view: NSView?
}

struct ChatMenuAnchorView: NSViewRepresentable {
    let anchor: ChatMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }

    /// Top-left origin, so a menu placed at zero meets the chip's own corner.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
