import SwiftUI

/// Fork: what a message in AI Chat's window can do beyond copy and regenerate.
struct ChatMessageActions {
    /// The question the composer is editing, outlined in the transcript.
    var editingID: UUID?
    var canEdit: Bool
    var edit: (UUID) -> Void
    var branch: (UUID) -> Void
}

extension EnvironmentValues {
    /// Set by the window's transcript only; Quick AI leaves it nil and draws as upstream does.
    @Entry var chatMessageActions: ChatMessageActions?
}

extension View {
    /// The window's transcript, wired to the workspace: edit, branch, fold and the editing outline.
    func chatWorkspaceActions(for chat: AIChatState) -> some View {
        modifier(ChatWorkspaceActionsWiring(chat: chat))
    }

    /// The edited question's outline and its Editing tag; a reply is never edited, so takes neither.
    @ViewBuilder func chatEditing(
        _ message: ChatMessage, actions: ChatMessageActions?, radius: CGFloat
    ) -> some View {
        if message.role == .user {
            modifier(ChatEditingOutline(editing: actions?.editingID == message.id, radius: radius))
        } else {
            self
        }
    }

    /// A long question folds to ten lines with Show more; find opens it.
    func chatFolding(_ text: String, forcedOpen: Bool, actions: ChatMessageActions?) -> some View {
        modifier(ChatFold(text: text, forcedOpen: forcedOpen, inWindow: actions != nil))
    }
}

private struct ChatWorkspaceActionsWiring: ViewModifier {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let chat: AIChatState

    func body(content: Content) -> some View {
        let chatID = chat.session.id
        content.environment(
            \.chatMessageActions,
            ChatMessageActions(
                editingID: workspace.editingMessageID(in: chat), canEdit: !chat.isStreaming,
                edit: { [workspace, chat] in workspace.beginEditing($0, in: chat) },
                branch: { [workspace] in workspace.branch(chatID, through: $0) }))
    }
}

/// Branch on a finished reply, Edit on a question; shown with the footer's Copy, on hover.
struct ChatMessageActionButtons: View {
    let message: ChatMessage
    /// Read once by the message, which hands it to each of its parts.
    let actions: ChatMessageActions?

    var body: some View {
        if let actions {
            if message.role == .user, actions.canEdit {
                button("pencil", label: "Edit Message", hue: .purple) { actions.edit(message.id) }
            }
            if message.role == .assistant, message.state != .streaming {
                button("arrow.triangle.branch", label: "Branch Chat", hue: .blue) { actions.branch(message.id) }
            }
        }
    }

    private func button(
        _ symbol: String, label: LocalizedStringResource, hue: RaycastHue, action: @escaping () -> Void
    ) -> some View {
        ChatHoverGlyphButton(symbol: symbol, hue: hue, action: action)
            .chatToolTip(String(localized: label))
            .accessibilityLabel(Text(label))
    }
}

/// A footer glyph: secondary at rest, its hue under the pointer.
private struct ChatHoverGlyphButton: View {
    @Environment(\.metrics) private var metrics
    let symbol: String
    let hue: RaycastHue
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(metrics.typography.keyCap)
                .foregroundStyle(hovered ? hue.color : Theme.Colors.textSecondary)
                .frame(width: metrics.size.chatMessageAction, height: metrics.size.chatMessageAction)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct ChatEditingOutline: ViewModifier {
    let editing: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Theme.Colors.chatEditingEdge, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topLeading) {
                if editing {
                    Label("Editing", systemImage: "pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xxs)
                        .background(Capsule().fill(Theme.Colors.accent))
                        .offset(x: -Theme.Spacing.sm, y: -Theme.Spacing.md)
                }
            }
            .animation(.easeOut(duration: Theme.Duration.chatFooter), value: editing)
    }
}

private struct ChatFold: ViewModifier {
    let text: String
    let forcedOpen: Bool
    let inWindow: Bool
    @State private var expanded = false

    func body(content: Content) -> some View {
        if inWindow, ChatMessageFold.folds(text) {
            let open = expanded || forcedOpen
            VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                content.lineLimit(open ? nil : ChatMessageFold.lineLimit)
                Button(open ? "Collapse" : "Show more") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: Theme.Colors.accentInk))
                    .font(.callout.weight(.medium))
                    .disabled(forcedOpen)
            }
        } else {
            content
        }
    }
}

/// Above the composer while a sent question is being edited: what Return and Esc will do.
struct ChatEditingBanner: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let chat: AIChatState

    var body: some View {
        if workspace.editingMessageID(in: chat) != nil {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "pencil")
                    .foregroundStyle(Theme.Colors.accent)
                Text("Editing a message: sending replaces it and every reply after it.")
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer(minLength: Theme.Spacing.sm)
                Button("Cancel  Esc") { workspace.cancelEditing(in: chat) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: Theme.Colors.accentInk))
            }
            .font(.callout)
            .padding(.horizontal, Theme.Spacing.sm)
        }
    }
}
