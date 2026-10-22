import AppKit
import SwiftUI

extension View {
    /// Fork: the composer's note picker over the transcript, and `@note` typed into the draft.
    func notePicker(
        chat: AIChatState, chats: AIChatCoordinator, editor: ComposerTextViewHandle
    ) -> some View {
        modifier(NotePickerModifier(chat: chat, chats: chats, editor: editor))
    }
}

/// Holds the picker's model only while it is shown, so nothing of it lives between pickers.
private struct NotePickerModifier: ViewModifier {
    let chat: AIChatState
    let chats: AIChatCoordinator
    let editor: ComposerTextViewHandle
    @State private var model: NotePickerModel?

    private var notes: NotesAICoordinator { chats.notes }
    private var isShown: Bool { notes.isAvailable && notes.pickerChatID == chat.session.id }

    func body(content: Content) -> some View {
        content
            // In the transcript's frame, like the context card, so it can never leave the window.
            .overlay(alignment: .bottom) {
                if let model, isShown {
                    HStack {
                        NotePickerCard(model: model, onPick: pick, onCancel: cancel)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: Theme.Size.aiChatReadingWidth)
                    .padding(.horizontal, Theme.Spacing.xxl)
                    .padding(.bottom, Theme.Spacing.sm)
                    .transition(.opacity)
                    .task(id: ObjectIdentifier(model)) { await model.load(after: notes.flush) }
                }
            }
            // A switched chat or Notes switched off closes it for good, never to reopen by itself.
            .onChange(of: isShown, initial: true) { _, shown in
                model?.cancel()
                model = shown ? notes.makePickerModel() : nil
                if !shown, notes.pickerChatID != nil { notes.dismissPicker() }
            }
            .onChange(of: chat.draft) { old, new in
                guard notes.isAvailable,
                    let draft = NoteMention.consume(
                        old: old, new: new,
                        reservedAtStart: chats.addressedServer(in: NoteMention.token) != nil)
                else { return }
                chat.draft = draft
                notes.presentPicker(for: chat, fromMention: true)
            }
    }

    private func pick(_ summary: NoteSummary) {
        notes.dismissPicker()
        notes.attach(summary, to: chat, via: chats)
        focusComposer()
    }

    /// Esc or a click away; a typed `@note ` goes back where it was.
    private func cancel() {
        guard notes.pickerChatID == chat.session.id else { return }
        let restores = notes.restoresMention
        notes.dismissPicker()
        if restores { chat.draft += NoteMention.token + " " }
        focusComposer()
    }

    private func focusComposer() {
        guard let textView = editor.textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}

/// Tinycast's own card, never a popover: a search field over the notes, newest first.
private struct NotePickerCard: View {
    let model: NotePickerModel
    let onPick: (NoteSummary) -> Void
    let onCancel: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var listHeight: CGFloat = 0

    private var maxListHeight: CGFloat {
        Theme.Size.noteSwitcher.height - Theme.Size.noteSearchHeight
    }

    var body: some View {
        @Bindable var model = model
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.menuPanel, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Colors.textSecondary)
                TextField("Search notes…", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let selected = model.selected { onPick(selected) } }
                    .onExitCommand(perform: onCancel)
                    .accessibilityLabel("Search Notes")
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(height: Theme.Size.noteSearchHeight)
            results
        }
        .frame(width: Theme.Size.noteSwitcher.width)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        // Solid under the glass, so the transcript's text never shows through the card.
        .background { shape.fill(Theme.Colors.windowSurface) }
        .shadow(color: Theme.Colors.tooltipShadow, radius: Theme.Spacing.xl, y: Theme.Spacing.xs)
        .onKeyPress(.downArrow) {
            model.move(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            model.move(by: -1)
            return .handled
        }
        // Popover-like: a click anywhere else takes the focus, and the card goes with it.
        .onChange(of: searchFocused) { _, focused in
            if !focused { onCancel() }
        }
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                searchFocused = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attach Note…")
    }

    @ViewBuilder private var results: some View {
        if model.rows.isEmpty {
            HStack(spacing: Theme.Spacing.md) {
                SymbolImage(
                    name: model.isLoading || model.isSearching ? "clock" : "text.page",
                    size: Theme.Size.noteGlyph)
                Text(model.isLoading || model.isSearching ? "Searching notes…" : "No notes found")
            }
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xl)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, summary in
                            NotePickerRow(summary: summary, selected: index == model.selection) {
                                onPick(summary)
                            }
                            .id(summary.id)
                        }
                    }
                    .padding(Theme.Spacing.md)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(listHeight, maxListHeight))
                .overflowFade()
                .onChange(of: model.selection) { _, selection in
                    guard model.rows.indices.contains(selection) else { return }
                    proxy.scrollTo(model.rows[selection].id, anchor: .center)
                }
            }
        }
    }
}

private struct NotePickerRow: View {
    let summary: NoteSummary
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
            HStack(spacing: Theme.Spacing.lg) {
                SymbolImage(name: "text.page", size: Theme.Size.noteGlyph)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(summary.displayTitle)
                    .font(Theme.Typography.rowTitle)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.md)
                // Formatted once, not a live relative Text, which would keep a timer running.
                Text(summary.modifiedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A click must not take the search field's focus, or the card would close before the pick.
        .focusable(false)
        .onHover { hovered = $0 }
        .accessibilityLabel(summary.displayTitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
