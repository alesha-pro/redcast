import SwiftUI

/// Fork: AI Chat's sidebar: Pinned, folders, Recent by day, then Archived and Recently Deleted.
struct ChatWorkspaceSidebar: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    @State private var renameText = ""
    @State private var showsArchived = false
    @State private var showsDeleted = false
    @State private var renamingFolder: UUID?
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool

    private var history: ChatHistoryStore { workspace.history }
    private var chats: AIChatSurfacesState { workspace.chats }

    var body: some View {
        @Bindable var workspace = workspace
        let layout = workspace.sidebarLayout
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                ChatSidebarSearchField(query: $workspace.query, focused: $searchFocused)
                Button {
                    newFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(Theme.Typography.composerSymbol)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .frame(width: Theme.Size.aiChatSearchField, height: Theme.Size.aiChatSearchField)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Folder")
                .accessibilityLabel("New Folder")
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.md)
            if layout.isEmpty, workspace.workspace.trashed.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(layout)
            }
        }
        .padding(.top, Theme.Spacing.md)
        .overlay {
            if let folder = workspace.editingFolder {
                ChatFolderEditor(folder: folder)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: workspace.editingFolder?.id)
        .task(id: workspace.query) {
            let trimmed = workspace.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                workspace.contentMatches = []
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            workspace.contentMatches = history.conversationIDs(containing: trimmed)
        }
        .onExitCommand {
            if workspace.editingFolder != nil {
                workspace.editingFolder = nil
            } else if !workspace.query.isEmpty {
                workspace.query = ""
            } else {
                workspace.host?.closeWindow()
            }
        }
    }

    private func list(_ layout: ChatSidebarLayout) -> some View {
        let order = layout.shortcutOrder
        let answering = chats.answeringIDs
        let openID = chats.window.session.id
        let badges = workspace.showsShortcuts ? order : []
        func row(_ chat: ChatConversation, folder: ChatFolder? = nil) -> some View {
            ChatWorkspaceRow(
                conversation: chat, folder: folder, isAnswering: answering.contains(chat.id),
                isSelected: chat.id == openID,
                shortcut: ChatShortcutIndex.badge(for: chat.id, in: badges)
            ) {
                title(of: chat)
            }
            .simultaneousGesture(TapGesture().onEnded { open(chat.id) })
            .draggable(ChatDragPayload.text(for: chat.id))
            .contextMenu { ChatRowMenu(conversation: chat, beginRename: beginRename) }
        }
        return List {
            if let results = layout.results {
                Section {
                    ForEach(results) { row($0) }
                } header: {
                    ChatSectionHeader(title: "Results", symbol: "magnifyingglass", hue: .blue)
                }
            } else {
                if !layout.pinned.isEmpty {
                    Section {
                        ForEach(layout.pinned) { row($0) }
                    } header: {
                        ChatSectionHeader(title: "Pinned", symbol: "pin.fill", hue: .yellow)
                            .chatDropTarget { workspace.pin($0) }
                    }
                }
                Section {
                    ForEach(layout.folders) { group in
                        ChatFolderRow(
                            group: group,
                            isRenaming: renamingFolder == group.id,
                            renameText: $renameText, renameFocused: $renameFocused,
                            commitRename: { commitFolderRename(group.folder) },
                            beginRename: { beginRename(folder: group.folder) })
                        if !group.folder.isCollapsed {
                            ForEach(group.chats) { row($0, folder: group.folder) }
                        }
                    }
                } header: {
                    ChatSectionHeader(title: "Folders", symbol: "folder.fill", hue: .purple) {
                        Button(action: newFolder) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                        .help("New Folder")
                        .accessibilityLabel("New Folder")
                    }
                }
                ForEach(layout.recent) { day in
                    Section {
                        ForEach(day.chats) { row($0) }
                    } header: {
                        ChatSectionHeader(verbatim: day.title, symbol: nil, hue: .red)
                            .chatDropTarget { workspace.move($0, to: nil) }
                    }
                }
                if !layout.archived.isEmpty {
                    Section(isExpanded: $showsArchived) {
                        ForEach(layout.archived) { row($0) }
                    } header: {
                        ChatSectionHeader(
                            title: "Archived", symbol: "archivebox.fill", hue: .gray,
                            count: layout.archived.count)
                    }
                }
            }
            let trashed = workspace.workspace.trashed
            if !trashed.isEmpty {
                Section(isExpanded: $showsDeleted) {
                    ForEach(trashed, id: \.id) { entry in
                        ChatTrashRow(id: entry.id, title: entry.title, deletedAt: entry.deletedAt)
                    }
                } header: {
                    ChatSectionHeader(
                        title: "Recently Deleted", symbol: "trash.fill", hue: .gray, count: trashed.count)
                        .contextMenu {
                            Button("Empty Recently Deleted…", systemImage: "trash.slash", role: .destructive) {
                                Task { await workspace.emptyTrash() }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var emptyState: some View {
        if !history.isAvailable {
            ContentUnavailableView(
                "History Unavailable", systemImage: "exclamationmark.triangle",
                description: Text("Chats can't be saved on this Mac right now."))
        } else if !workspace.query.isEmpty {
            ContentUnavailableView.search(text: workspace.query)
        } else {
            ContentUnavailableView(
                "No Chats Yet", systemImage: "bubble.left.and.bubble.right",
                description: Text("Conversations stay on this Mac."))
        }
    }

    @ViewBuilder private func title(of conversation: ChatConversation) -> some View {
        if workspace.renaming == conversation.id {
            TextField("Chat name", text: $renameText, prompt: Text(conversation.title))
                .textFieldStyle(.plain)
                .focused($renameFocused)
                .onSubmit { commitRename(conversation.id) }
                .onExitCommand { workspace.renaming = nil }
                .onChange(of: renameFocused) { _, focused in
                    if !focused { commitRename(conversation.id) }
                }
        } else {
            Text(conversation.displayTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(conversation) })
        }
    }

    private func beginRename(_ conversation: ChatConversation) {
        renameText = conversation.customTitle ?? conversation.displayTitle
        workspace.renaming = conversation.id
        Task { @MainActor in renameFocused = true }
    }

    private func commitRename(_ id: UUID) {
        guard workspace.renaming == id else { return }
        workspace.renaming = nil
        history.rename(id: id, to: renameText)
    }

    private func newFolder() {
        guard
            let folder = workspace.createFolder(
                named: String(localized: "New Folder"), hue: ChatFolder.nextHue(after: workspace.workspace.folders),
                symbol: ChatFolder.symbols[0], instructions: nil, agentID: nil)
        else { return }
        workspace.query = ""
        beginRename(folder: folder)
    }

    private func beginRename(folder: ChatFolder) {
        renameText = folder.name
        renamingFolder = folder.id
        Task { @MainActor in renameFocused = true }
    }

    private func commitFolderRename(_ folder: ChatFolder) {
        guard renamingFolder == folder.id else { return }
        renamingFolder = nil
        var renamed = folder
        renamed.name = renameText
        workspace.updateFolder(renamed)
    }

    /// The open chat wears the accent's wash; the list itself selects nothing, so no grey bar.
    private func open(_ id: UUID) {
        guard id != chats.window.session.id, workspace.renaming != id else { return }
        workspace.host?.openChat(id: id)
    }
}

/// Fork: a chat dragged between sections travels as text only the sidebar reads back.
enum ChatDragPayload {
    private static let prefix = "tinycast-chat:"

    static func text(for id: UUID) -> String { prefix + id.uuidString }

    static func chat(in text: String) -> UUID? {
        guard text.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(text.dropFirst(prefix.count)))
    }
}

extension View {
    /// Takes a dragged chat and says so with the accent's wash while one hovers.
    func chatDropTarget(_ drop: @escaping (UUID) -> Void) -> some View {
        modifier(ChatDropTarget(drop: drop))
    }
}

private struct ChatDropTarget: ViewModifier {
    let drop: (UUID) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(isTargeted ? Theme.Colors.chatDropTarget : Color.clear)
                    .padding(.horizontal, -Theme.Spacing.sm)
            }
            .dropDestination(for: String.self) { items, _ in
                let ids = items.compactMap(ChatDragPayload.chat(in:))
                for id in ids { drop(id) }
                return !ids.isEmpty
            } isTargeted: {
                isTargeted = $0
            }
    }
}

/// A section's name in its own colour, so Pinned, Folders and the days read apart at a glance.
struct ChatSectionHeader<Accessory: View>: View {
    let title: Text
    let symbol: String?
    let hue: RaycastHue
    var count: Int?
    @ViewBuilder var accessory: Accessory

    init(
        title: LocalizedStringResource, symbol: String?, hue: RaycastHue, count: Int? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = Text(title)
        self.symbol = symbol
        self.hue = hue
        self.count = count
        self.accessory = accessory()
    }

    init(
        verbatim: String, symbol: String?, hue: RaycastHue, count: Int? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        title = Text(verbatim: verbatim)
        self.symbol = symbol
        self.hue = hue
        self.count = count
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: Theme.Size.chatHeaderGlyph, weight: .semibold))
                    .foregroundStyle(hue.ink)
            }
            title
                .font(Theme.Typography.sectionHeader.weight(.semibold))
                .foregroundStyle(hue == .gray ? Theme.Colors.textSecondary : hue.ink)
            if let count {
                Text(verbatim: "\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer(minLength: 0)
            accessory
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .contentShape(Rectangle())
    }
}

/// A chat's row; content fills the cell so hover never blinks between rows.
private struct ChatWorkspaceRow<Title: View>: View {
    let conversation: ChatConversation
    let folder: ChatFolder?
    let isAnswering: Bool
    let isSelected: Bool
    let shortcut: String?
    @ViewBuilder let title: Title
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let folder {
                Capsule()
                    .fill(folder.hue.color)
                    .frame(width: Theme.Size.chatFolderBar)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .padding(.leading, Theme.Size.chatFolderIndent)
            }
            title
            Spacer(minLength: 0)
            if let shortcut {
                Text(verbatim: "⌘\(shortcut)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(minWidth: Theme.Size.chatShortcutBadge, minHeight: Theme.Size.chatShortcutBadge)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.keyCap).fill(Theme.Colors.controlSurface))
            } else if isAnswering {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Answering")
            } else if conversation.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(RaycastHue.yellow.color)
                    .accessibilityLabel("Pinned")
            }
        }
        .frame(maxHeight: .infinity)
        .listRowInsets(EdgeInsets())
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .listRowBackground(background)
        .help(conversation.displayTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Theme.Colors.chatSelectedRow)
                .padding(.horizontal, Theme.Spacing.lg)
        } else if isHovered {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Theme.Colors.rowHover)
                .padding(.horizontal, Theme.Spacing.lg)
        }
    }
}

/// A folder: its tile, name and count; a click folds it, a drop files the chat into it.
private struct ChatFolderRow: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let group: ChatSidebarLayout.FolderGroup
    let isRenaming: Bool
    @Binding var renameText: String
    var renameFocused: FocusState<Bool>.Binding
    let commitRename: () -> Void
    let beginRename: () -> Void
    @State private var isHovered = false

    private var folder: ChatFolder { group.folder }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "chevron.right")
                .font(Theme.Typography.disclosure)
                .foregroundStyle(Theme.Colors.textTertiary)
                .rotationEffect(.degrees(folder.isCollapsed ? 0 : 90))
            ChatFolderTile(symbol: folder.symbol, hue: folder.hue)
            if isRenaming {
                TextField("Folder name", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused(renameFocused)
                    .onSubmit(commitRename)
                    .onChange(of: renameFocused.wrappedValue) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(verbatim: folder.name)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isHovered {
                Button {
                    workspace.newChat(in: folder)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(folder.hue.color)
                }
                .buttonStyle(.plain)
                .help("New Chat in Folder")
                .accessibilityLabel("New Chat in Folder")
            } else if !group.chats.isEmpty {
                Text(verbatim: "\(group.chats.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture { workspace.toggleCollapsed(folder.id) }
        .chatDropTarget { workspace.move($0, to: folder.id) }
        .contextMenu { ChatFolderMenu(folder: folder, beginRename: beginRename) }
        .accessibilityElement(children: .combine)
        .accessibilityHint(folder.isCollapsed ? "Expands the folder" : "Collapses the folder")
    }
}

/// A folder's colour and glyph on a tile: white ink on the hue, in both appearances.
struct ChatFolderTile: View {
    let symbol: String
    let hue: RaycastHue
    var size: CGFloat = Theme.Size.chatFolderTile

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * Theme.Size.glyphTileCorner, style: .continuous)
                    .fill(hue.tileColor))
            .accessibilityHidden(true)
    }
}

/// A deleted chat: dimmed, never opened, restored or deleted for good from its menu.
private struct ChatTrashRow: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let id: UUID
    let title: String
    let deletedAt: Date

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(verbatim: title.isEmpty ? String(localized: "Untitled Chat") : title)
                .lineLimit(1)
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer(minLength: 0)
            Text(deletedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .contentShape(.rect)
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward") { workspace.restore(id) }
            Button("Delete Permanently…", systemImage: "trash", role: .destructive) {
                Task { await workspace.deleteForever(id) }
            }
        }
        .help("Deleted chats are removed for good after 60 days.")
    }
}

/// A chat's menu: pin, file, archive, rename, copy, branch, delete.
struct ChatRowMenu: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let conversation: ChatConversation
    let beginRename: (ChatConversation) -> Void

    var body: some View {
        let id = conversation.id
        let archived = workspace.workspace.isArchived(id)
        Button(
            conversation.isPinned ? "Unpin Chat" : "Pin Chat",
            systemImage: conversation.isPinned ? "pin.slash" : "pin"
        ) {
            if conversation.isPinned {
                workspace.history.setPinned(false, id: id)
            } else {
                workspace.pin(id)
            }
        }
        ChatMoveMenu(chat: id)
        Button(archived ? "Unarchive" : "Archive", systemImage: archived ? "tray.and.arrow.up" : "archivebox") {
            archived ? workspace.unarchive(id) : workspace.archive(id)
        }
        Button("Rename…", systemImage: "pencil") { beginRename(conversation) }
        Divider()
        Button("Copy Chat", systemImage: "doc.on.doc") { workspace.host?.copyChat(id: id) }
        Button("Branch Chat", systemImage: "arrow.triangle.branch") { workspace.branch(id) }
        Button("Export as Markdown…", systemImage: "square.and.arrow.up") {
            workspace.host?.exportChat(id: id)
        }
        Divider()
        Button("Delete Chat", systemImage: "trash", role: .destructive) { workspace.trash(id) }
            .help("Moves it to Recently Deleted for 60 days")
    }
}

/// Move to Folder: every folder, Recent, and a new folder made for this chat.
struct ChatMoveMenu: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let chat: UUID

    var body: some View {
        let current = workspace.workspace.folderID(of: chat)
        Menu {
            Button("Recent", systemImage: "clock") { workspace.move(chat, to: nil) }
                .disabled(current == nil)
            if !workspace.workspace.folders.isEmpty { Divider() }
            ForEach(workspace.workspace.folders) { folder in
                Button {
                    workspace.move(chat, to: folder.id)
                } label: {
                    Label {
                        Text(verbatim: folder.name)
                    } icon: {
                        Image(nsImage: ChatFolderTileImage.make(symbol: folder.symbol, hue: folder.hue))
                    }
                }
                .disabled(current == folder.id)
            }
            Divider()
            Button("New Folder…", systemImage: "folder.badge.plus") {
                if let folder = workspace.createFolder(
                    named: String(localized: "New Folder"),
                    hue: ChatFolder.nextHue(after: workspace.workspace.folders),
                    symbol: ChatFolder.symbols[0], instructions: nil, agentID: nil)
                {
                    workspace.move(chat, to: folder.id)
                    workspace.editingFolder = folder
                }
            }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }
    }
}

/// A folder's menu: a new chat in it, its name, colour and icon, its settings, and delete.
private struct ChatFolderMenu: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let folder: ChatFolder
    let beginRename: () -> Void

    var body: some View {
        Button("New Chat in Folder", systemImage: "square.and.pencil") { workspace.newChat(in: folder) }
        Divider()
        Button("Rename…", systemImage: "pencil", action: beginRename)
        Menu {
            ForEach(ChatFolder.hues) { hue in
                Button {
                    var changed = folder
                    changed.color = hue.rawValue
                    workspace.updateFolder(changed)
                } label: {
                    Label {
                        Text(hue.title)
                    } icon: {
                        Image(nsImage: ChatFolderTileImage.make(symbol: "circle.fill", hue: hue))
                    }
                }
            }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
        Button("Folder Settings…", systemImage: "slider.horizontal.3") { workspace.editingFolder = folder }
        Divider()
        Button("Delete Folder…", systemImage: "trash", role: .destructive) {
            Task { await workspace.deleteFolder(folder) }
        }
    }
}

/// A menu item draws an image, not a view, so a folder's tile is drawn once per menu.
enum ChatFolderTileImage {
    static func make(symbol: String, hue: RaycastHue, side: CGFloat = 16) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let tile = NSBezierPath(
                roundedRect: rect, xRadius: side * Theme.Size.glyphTileCorner, yRadius: side * Theme.Size.glyphTileCorner)
            hue.tileNSColor.setFill()
            tile.fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.55, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            {
                let size = glyph.size
                glyph.draw(in: NSRect(
                    x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                    width: size.width, height: size.height))
            }
            return true
        }
    }
}

/// The sidebar's search field, drawn the way Settings' own is so the two windows match.
private struct ChatSidebarSearchField: View {
    @Binding var query: String
    @FocusState.Binding var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("", text: $query, prompt: Text("Search"))
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($focused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: Theme.Size.aiChatSearchField)
        .background { Color.clear.frosted(in: Capsule()) }
        .contentShape(.rect)
        .onTapGesture { focused = true }
        .help("Search titles and messages")
        .accessibilityLabel("Search chats")
    }
}
