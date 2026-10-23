import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

extension View {
    /// Fork: an ACP agent's slash commands over the composer while the draft is typing one.
    func acpCommands(
        chat: AIChatState, chats: AIChatCoordinator, editor: ComposerTextViewHandle
    ) -> some View {
        modifier(ACPCommandPickerModifier(chat: chat, agents: chats.agents, editor: editor))
    }
}

/// Exists only while the draft could name a command, so no key monitor runs at any other time.
@MainActor
@Observable
private final class ACPCommandPicker {
    var selection = 0
    /// The draft Esc hid the list on; any edit brings the list back.
    var hiddenDraft: String?

    @ObservationIgnored private let chat: AIChatState
    @ObservationIgnored private let agents: AgentCoordinator
    @ObservationIgnored private let editor: ComposerTextViewHandle
    @ObservationIgnored private var monitor: Any?

    init(chat: AIChatState, agents: AgentCoordinator, editor: ComposerTextViewHandle) {
        self.chat = chat
        self.agents = agents
        self.editor = editor
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    isolated deinit {
        stop()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    var matches: [ACPCommand] {
        guard chat.draft != hiddenDraft else { return [] }
        return ACPCommand.matches(for: chat.draft, in: agents.commands(for: chat))
    }

    var selected: Int {
        min(selection, max(matches.count - 1, 0))
    }

    /// Through the text view, so the completion is one undoable edit and the caret lands after it.
    func complete(_ command: ACPCommand) {
        hiddenDraft = nil
        guard let textView = editor.textView else {
            chat.draft = command.completion
            return
        }
        textView.insertText(
            command.completion, replacementRange: NSRange(location: 0, length: textView.string.utf16.count))
        textView.window?.makeFirstResponder(textView)
    }

    /// Only the composer's own keys, never while an input method is composing.
    private func handle(_ event: NSEvent) -> Bool {
        guard let textView = editor.textView, event.window === textView.window,
            textView.window?.firstResponder === textView, !textView.hasMarkedText(),
            event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
        else { return false }
        let matches = matches
        guard !matches.isEmpty else { return false }
        let command = matches[selected]
        switch Int(event.keyCode) {
        case kVK_DownArrow:
            selection = min(selected + 1, matches.count - 1)
        case kVK_UpArrow:
            selection = max(selected - 1, 0)
        case kVK_Tab:
            complete(command)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // A name typed out in full sends, so `/compact` and Return run it at once.
            guard !command.isTypedOut(in: chat.draft) else { return false }
            complete(command)
        case kVK_Escape:
            hiddenDraft = chat.draft
        default:
            return false
        }
        return true
    }
}

private struct ACPCommandPickerModifier: ViewModifier {
    let chat: AIChatState
    let agents: AgentCoordinator
    let editor: ComposerTextViewHandle
    @State private var picker: ACPCommandPicker?

    /// Whether the draft could name a command at all; the picker narrows it from there.
    private var isTyping: Bool {
        ACPCommand.typedName(in: chat.draft) != nil && !agents.commands(for: chat).isEmpty
    }

    func body(content: Content) -> some View {
        content
            // In the transcript's frame, like the note picker, so it can never leave the window.
            .overlay(alignment: .bottom) {
                let matches = picker?.matches ?? []
                if let picker, !matches.isEmpty {
                    ACPCommandCard(commands: matches, selection: min(picker.selection, matches.count - 1)) {
                        picker.complete($0)
                    }
                    .frame(maxWidth: Theme.Size.aiChatReadingWidth)
                    .padding(.horizontal, Theme.Spacing.xxl)
                    .padding(.bottom, Theme.Spacing.sm)
                    .transition(.opacity)
                }
            }
            .onChange(of: isTyping, initial: true) { _, typing in
                picker?.stop()
                picker = typing ? ACPCommandPicker(chat: chat, agents: agents, editor: editor) : nil
            }
            .onChange(of: chat.draft) { picker?.selection = 0 }
            .onDisappear {
                picker?.stop()
                picker = nil
            }
    }
}

/// Tinycast's own card, never a popover; the composer keeps the focus while it is shown.
private struct ACPCommandCard: View {
    @Environment(\.metrics) private var metrics
    let commands: [ACPCommand]
    let selection: Int
    let onPick: (ACPCommand) -> Void
    @State private var listHeight: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.menuPanel, style: .continuous)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: metrics.size.menuRowSpacing) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        ACPCommandRow(command: command, selected: index == selection) { onPick(command) }
                            .id(command.id)
                    }
                }
                .padding(metrics.spacing.md)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(listHeight, metrics.size.menuRowsMaxHeight + metrics.spacing.md * 2))
            .overflowFade()
            .onChange(of: selection) { _, selection in
                guard commands.indices.contains(selection) else { return }
                proxy.scrollTo(commands[selection].id, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        // Solid under the glass, so the transcript's text never shows through the card.
        .background { shape.fill(Theme.Colors.windowSurface) }
        .shadow(color: Theme.Colors.tooltipShadow, radius: Theme.Spacing.xl, y: Theme.Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent Commands")
    }
}

private struct ACPCommandRow: View {
    @Environment(\.metrics) private var metrics
    let command: ACPCommand
    let selected: Bool
    let onPick: () -> Void
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: metrics.spacing.lg) {
                Text(verbatim: "/" + command.name)
                    .font(metrics.typography.rowTitle)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let hint = command.hint {
                    Text(verbatim: hint)
                        .font(metrics.typography.rowTrailing)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: metrics.spacing.md)
                Text(verbatim: command.description)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, metrics.spacing.md)
            .frame(height: metrics.size.menuRowHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A click must not take the composer's focus, or typing would stop where the click landed.
        .focusable(false)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(verbatim: "/" + command.name))
        .accessibilityValue(Text(verbatim: command.description))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
