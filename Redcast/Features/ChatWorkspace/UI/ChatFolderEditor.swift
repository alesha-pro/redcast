import SwiftUI

/// Fork: a folder's settings, slid over the sidebar: name, colour, icon, instructions and agent.
struct ChatFolderEditor: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    @State private var draft: ChatFolder
    @State private var instructions: String

    init(folder: ChatFolder) {
        _draft = State(initialValue: folder)
        _instructions = State(initialValue: folder.instructions ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    workspace.editingFolder = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: Theme.Size.aiChatSearchField, height: Theme.Size.aiChatSearchField)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to Chats")
                .accessibilityLabel("Back to Chats")
                ChatFolderTile(symbol: draft.symbol, hue: draft.hue, size: Theme.Size.chatIconCell)
                Text("Folder Settings").font(.headline)
                Spacer(minLength: 0)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    field("Name") {
                        TextField("Folder name", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(save)
                    }
                    field("Color") { swatches }
                    field("Icon") { icons }
                    field("Instructions") {
                        ChatInstructionsField(
                            text: $instructions,
                            prompt: "Instructions for every chat in this folder.")
                        Text("Sent after the system prompt, before a chat's own instructions.")
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                    field("New chats start with") { agentMenu }
                    Button(role: .destructive) {
                        Task {
                            await workspace.deleteFolder(draft)
                            if workspace.workspace.folder(id: draft.id) == nil { workspace.editingFolder = nil }
                        }
                    } label: {
                        Label("Delete Folder…", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.Colors.destructive)
                }
                .padding(.bottom, Theme.Spacing.xl)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Colors.windowSurface)
        .onChange(of: draft) { save() }
        .onChange(of: instructions) { save() }
        .onExitCommand { workspace.editingFolder = nil }
    }

    private func field(_ title: LocalizedStringResource, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Colors.textSecondary)
            content()
        }
    }

    private var swatches: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(ChatFolder.hues) { hue in
                Button {
                    draft.color = hue.rawValue
                } label: {
                    Circle()
                        .fill(hue.tileColor)
                        .frame(width: Theme.Size.chatSwatch, height: Theme.Size.chatSwatch)
                        .overlay {
                            if draft.hue == hue {
                                Circle().strokeBorder(Theme.Colors.textPrimary, lineWidth: 2)
                                    .padding(-3)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(hue.title)
                .accessibilityLabel(hue.title)
                .accessibilityAddTraits(draft.hue == hue ? .isSelected : [])
            }
        }
        .padding(.leading, Theme.Spacing.xxs)
    }

    private var icons: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Theme.Size.chatIconCell), spacing: Theme.Spacing.sm)],
            alignment: .leading, spacing: Theme.Spacing.sm
        ) {
            ForEach(ChatFolder.symbols, id: \.self) { symbol in
                Button {
                    draft.symbol = symbol
                } label: {
                    Group {
                        if draft.symbol == symbol {
                            ChatFolderTile(symbol: symbol, hue: draft.hue, size: Theme.Size.chatIconCell)
                        } else {
                            Image(systemName: symbol)
                                .font(.system(size: Theme.Size.chatIconCell * 0.5, weight: .semibold))
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .frame(width: Theme.Size.chatIconCell, height: Theme.Size.chatIconCell)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.Radius.barControl, style: .continuous)
                                        .fill(Theme.Colors.controlSurface))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol)
            }
        }
    }

    private var agentMenu: some View {
        let agents = workspace.host?.agentChoices ?? []
        let current = agents.first { $0.id == draft.agentID }
        return Menu {
            Button("No Agent") { draft.agentID = nil }
            if !agents.isEmpty {
                Divider()
                ForEach(agents) { agent in
                    Button {
                        draft.agentID = agent.id
                    } label: {
                        Label {
                            Text(verbatim: agent.name)
                        } icon: {
                            Image(nsImage: ChatFolderTileImage.make(symbol: agent.symbol, hue: agent.hue))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                if let current {
                    ChatFolderTile(symbol: current.symbol, hue: current.hue, size: Theme.Size.chatFolderTile)
                    Text(verbatim: current.name)
                } else {
                    Text("No Agent")
                }
            }
        }
        .fixedSize()
        .disabled(agents.isEmpty)
        .help(agents.isEmpty ? "Add an agent in Settings to start this folder's chats on it" : "")
    }

    private func save() {
        var folder = draft
        folder.instructions = instructions
        workspace.updateFolder(folder)
    }
}

/// A multi-line field with a placeholder, the settings sidebar's and the folder editor's.
struct ChatInstructionsField: View {
    @Binding var text: String
    let prompt: LocalizedStringResource

    var body: some View {
        TextEditor(text: $text)
            .font(.callout)
            .scrollContentBackground(.hidden)
            .frame(height: Theme.Size.chatInstructionsHeight)
            .padding(Theme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.barControl, style: .continuous)
                    .fill(Theme.Colors.controlSurface))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt)
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .padding(.horizontal, Theme.Spacing.sm + 1)
                        .padding(.vertical, Theme.Spacing.xs)
                        .allowsHitTesting(false)
                }
            }
    }
}
