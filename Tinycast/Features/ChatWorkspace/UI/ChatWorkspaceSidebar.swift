import SwiftUI

/// Fork: AI Chat's sidebar: Pinned, folders, Recent by day, then Archived and Recently Deleted.
struct ChatWorkspaceSidebar: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    @State private var renameText = ""
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
        .onChange(of: workspace.selectionContents(layout)) { _, contents in
            workspace.selection.reconcile(contents: contents)
        }
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
        @Bindable var workspace = workspace
        let order = layout.shortcutOrder
        let answering = chats.answeringIDs
        let openID = chats.window.session.id
        let badges = workspace.showsShortcuts ? order : []
        func row(_ row: ChatTreeRow, folder: ChatFolder? = nil) -> some View {
            let chat = row.chat
            return ChatWorkspaceRow(
                row: row, folder: folder, isAnswering: answering.contains(chat.id), isOpen: chat.id == openID,
                shortcut: ChatShortcutIndex.badge(for: chat.id, in: badges), click: { click(chat.id) }
            ) {
                title(of: chat)
            }
            .draggable(ChatDragPayload.text(for: workspace.dragged(chat.id)))
            .contextMenu { ChatRowContextMenu(conversation: chat, beginRename: beginRename) }
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
                            ForEach(group.rows) { row($0, folder: group.folder) }
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
                        ForEach(day.rows) { row($0) }
                    } header: {
                        ChatSectionHeader(verbatim: day.title, symbol: nil, hue: .red)
                            .chatDropTarget { workspace.move($0, to: nil) }
                    }
                }
                if !layout.archived.isEmpty {
                    Section(isExpanded: $workspace.showsArchived) {
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
                Section(isExpanded: $workspace.showsDeleted) {
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
        .safeAreaInset(edge: .bottom, spacing: 0) { ChatSelectionBar() }
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

    /// ⌘ toggles the row and ⇧ takes the range into the selection; a plain click opens the chat.
    private func click(_ id: UUID) {
        if workspace.click(id, workspace.clickKind) { open(id) }
    }

    /// The open chat wears the accent's wash; the list itself selects nothing, so no grey bar.
    private func open(_ id: UUID) {
        guard id != chats.window.session.id, workspace.renaming != id else { return }
        workspace.host?.openChat(id: id)
    }
}

/// Fork: chats dragged between sections travel as text only the sidebar reads back.
enum ChatDragPayload {
    private static let prefix = "tinycast-chat:"

    static func text(for ids: [UUID]) -> String { prefix + ids.map(\.uuidString).joined(separator: ",") }

    static func chats(in text: String) -> [UUID] {
        guard text.hasPrefix(prefix) else { return [] }
        return text.dropFirst(prefix.count).split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }
}

extension View {
    /// Takes dragged chats, a whole selection at once, and says so with the accent's wash.
    func chatDropTarget(_ drop: @escaping ([UUID]) -> Void) -> some View {
        modifier(ChatDropTarget(drop: drop))
    }
}

private struct ChatDropTarget: ViewModifier {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let drop: ([UUID]) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(isTargeted ? Theme.Colors.chatDropTarget : Color.clear)
                    .padding(.horizontal, -Theme.Spacing.sm)
            }
            .dropDestination(for: String.self) { items, _ in
                let ids = items.flatMap(ChatDragPayload.chats(in:))
                guard !ids.isEmpty else { return false }
                if ids.contains(where: workspace.selection.contains) { workspace.selection.clear() }
                drop(ids)
                return true
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
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let row: ChatTreeRow
    let folder: ChatFolder?
    let isAnswering: Bool
    let isOpen: Bool
    let shortcut: String?
    let click: () -> Void
    @ViewBuilder let title: Title
    @State private var isHovered = false

    private var conversation: ChatConversation { row.chat }

    /// The disclosure and the branch glyph take their own clicks; the rest of the row opens it.
    var body: some View {
        let isSelected = workspace.selection.contains(row.id)
        HStack(spacing: Theme.Spacing.sm) {
            if folder != nil || row.depth > 0 {
                HStack(spacing: Theme.Spacing.sm) {
                    if let folder {
                        Capsule()
                            .fill(folder.hue.color)
                            .frame(width: Theme.Size.chatFolderBar)
                            .padding(.vertical, Theme.Spacing.xxs)
                            .padding(.leading, Theme.Size.chatFolderIndent)
                    }
                    if row.depth > 0 {
                        ChatBranchGuideShape(guides: row.guides)
                            .stroke(Theme.Colors.chatBranchGuide, lineWidth: Theme.Size.hairline)
                            .frame(width: CGFloat(row.depth) * Theme.Size.chatBranchIndent)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .simultaneousGesture(TapGesture().onEnded(click))
            }
            if let origin = row.origin { ChatBranchOriginGlyph(chat: row.id, origin: origin) }
            title
                .contentShape(.rect)
                .simultaneousGesture(TapGesture().onEnded(click))
                .layoutPriority(1)
            if row.branches > 0 { ChatBranchDisclosure(chat: row.id, isFolded: row.isFolded) }
            HStack(spacing: Theme.Spacing.sm) {
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
            .contentShape(.rect)
            .simultaneousGesture(TapGesture().onEnded(click))
        }
        .frame(maxHeight: .infinity)
        .listRowInsets(EdgeInsets())
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .listRowBackground(ChatRowBackground(isSelected: isSelected, isOpen: isOpen, isHovered: isHovered))
        .help(conversation.displayTitle)
        .accessibilityAddTraits(isSelected || isOpen ? [.isButton, .isSelected] : .isButton)
    }
}

/// The selection wears the theme's selection with an accent edge; the open chat keeps its wash.
private struct ChatRowBackground: View {
    let isSelected: Bool
    var isOpen = false
    var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        Group {
            if isSelected {
                shape.fill(Theme.Colors.selection)
                    .overlay(shape.strokeBorder(Theme.Colors.chatSelectionEdge, lineWidth: Theme.Size.hairline))
                    .padding(.vertical, Theme.Size.hairline)
            } else if isOpen {
                shape.fill(Theme.Colors.chatSelectedRow)
            } else if isHovered {
                shape.fill(Theme.Colors.rowHover)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }
}

/// The lines from a parent down to its branches: one column per indent, an elbow into the last.
struct ChatBranchGuideShape: Shape {
    let guides: [ChatTreeRow.Guide]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = Theme.Size.chatBranchIndent
        let middle = rect.midY
        let radius = min(Theme.Size.chatBranchElbow, middle)
        for (column, guide) in guides.enumerated() {
            let x = rect.minX + CGFloat(column) * width + Theme.Size.chatBranchLine
            switch guide {
            case .blank:
                continue
            case .line:
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            case .elbow:
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: middle - radius))
                path.addQuadCurve(to: CGPoint(x: x + radius, y: middle), control: CGPoint(x: x, y: middle))
                path.addLine(to: CGPoint(x: rect.minX + CGFloat(column + 1) * width, y: middle))
            }
        }
        return path
    }
}

/// ▾ or ▸ after a parent's title: its branches shown or folded away, remembered per chat.
private struct ChatBranchDisclosure: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let chat: UUID
    let isFolded: Bool

    var body: some View {
        Button {
            workspace.toggleBranches(of: chat)
        } label: {
            Image(systemName: isFolded ? "chevron.right" : "chevron.down")
                .font(Theme.Typography.disclosure)
                .foregroundStyle(Theme.Colors.textTertiary)
                .frame(width: Theme.Size.chatShortcutBadge, height: Theme.Size.chatShortcutBadge)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFolded ? "Show Branches" : "Hide Branches")
    }
}

/// A branch listed away from its parent: a glyph naming the parent, which a click opens.
private struct ChatBranchOriginGlyph: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let chat: UUID
    let origin: ChatBranchOrigin

    var body: some View {
        let title = origin.title.isEmpty ? String(localized: "Untitled Chat") : origin.title
        let tip = String(localized: "Branched from \(title)")
        Button {
            workspace.openParent(of: chat)
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .chatToolTip(tip)
        .accessibilityLabel(tip)
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
            } else if group.count > 0 {
                Text(verbatim: "\(group.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture { if !isRenaming { workspace.toggleCollapsed(folder.id) } }
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
        let isSelected = workspace.selection.contains(id)
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
        .simultaneousGesture(
            TapGesture().onEnded {
                workspace.click(id, workspace.clickKind, inTrash: true)
            })
        .listRowBackground(ChatRowBackground(isSelected: isSelected))
        .contextMenu {
            if workspace.selection.count > 1, isSelected {
                ChatBulkTrashMenu()
            } else {
                Button("Restore", systemImage: "arrow.uturn.backward") { workspace.restore(id) }
                Button("Delete Permanently…", systemImage: "trash", role: .destructive) {
                    Task { await workspace.deleteForever(id) }
                }
            }
        }
        .help("Deleted chats are removed for good after 60 days.")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A row's menu: its own, or the selection's when it is one of several selected.
private struct ChatRowContextMenu: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let conversation: ChatConversation
    let beginRename: (ChatConversation) -> Void

    var body: some View {
        if workspace.selection.count > 1, workspace.selection.contains(conversation.id) {
            ChatBulkMenu()
        } else {
            ChatRowMenu(conversation: conversation, beginRename: beginRename)
        }
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

/// Several chats' menu: what applies to them all, done to every one at once.
struct ChatBulkMenu: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace

    var body: some View {
        let facts = workspace.selectionFacts
        Button(
            facts.pins ? "Pin Chats" : "Unpin Chats", systemImage: facts.pins ? "pin" : "pin.slash",
            action: workspace.togglePinSelection)
        ChatMoveMenu(selection: facts)
        if facts.anyFiled {
            Button("Remove from Folder", systemImage: "folder.badge.minus", action: workspace.removeSelectionFromFolders)
        }
        Button(
            facts.archives ? "Archive" : "Unarchive", systemImage: facts.archives ? "archivebox" : "tray.and.arrow.up",
            action: workspace.toggleArchiveSelection)
        Divider()
        Button("Copy Chats", systemImage: "doc.on.doc", action: workspace.copySelection)
        Divider()
        Button("Delete \(facts.ids.count) Chats…", systemImage: "trash", role: .destructive) {
            Task { await workspace.trashSelection() }
        }
    }
}

/// Recently Deleted's selection: back to where each was, or gone for good.
private struct ChatBulkTrashMenu: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace

    var body: some View {
        Button("Restore", systemImage: "arrow.uturn.backward", action: workspace.restoreSelection)
        Button("Delete Permanently…", systemImage: "trash", role: .destructive) {
            Task { await workspace.deleteSelectionForever() }
        }
    }
}

/// Move to Folder: every folder, Recent, and a new folder made for this chat or the selection.
struct ChatMoveMenu: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    private let chat: UUID?
    private let facts: ChatBulkFacts?

    init(chat: UUID) {
        self.chat = chat
        facts = nil
    }

    init(selection facts: ChatBulkFacts) {
        chat = nil
        self.facts = facts
    }

    var body: some View {
        Menu {
            ChatMoveMenuItems(chat: chat, facts: facts)
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }
    }
}

/// The folders a chat or the selection can go to; the check sits on the one they all share.
private struct ChatMoveMenuItems: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace
    let chat: UUID?
    let facts: ChatBulkFacts?

    var body: some View {
        let current = chat.map(workspace.workspace.folderID(of:)) ?? facts?.sharedFolder
        let anyFiled = facts?.anyFiled ?? (current != nil)
        Button("Recent", systemImage: "clock") { move(to: nil) }
            .disabled(!anyFiled)
        if !workspace.workspace.folders.isEmpty { Divider() }
        ForEach(workspace.workspace.folders) { folder in
            Button {
                move(to: folder.id)
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
            guard let chat else { return workspace.moveSelectionToNewFolder() }
            if let folder = workspace.createFolder(
                named: String(localized: "New Folder"),
                hue: ChatFolder.nextHue(after: workspace.workspace.folders),
                symbol: ChatFolder.symbols[0], instructions: nil, agentID: nil)
            {
                workspace.move(chat, to: folder.id)
                workspace.editingFolder = folder
            }
        }
    }

    private func move(to folder: UUID?) {
        if let chat {
            workspace.move(chat, to: folder)
        } else {
            workspace.moveSelection(to: folder)
        }
    }
}

/// Fork: with two or more chats selected, what can be done to all of them, under the list.
private struct ChatSelectionBar: View {
    @Environment(ChatWorkspaceCoordinator.self) private var workspace

    var body: some View {
        if workspace.selection.count > 1 {
            let inTrash = workspace.selectionIsInTrash
            let facts = workspace.selectionFacts
            HStack(spacing: Theme.Spacing.xs) {
                Text("\(workspace.selection.count) Selected")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.sm)
                if inTrash {
                    action("arrow.uturn.backward", "Restore", run: workspace.restoreSelection)
                    action("trash", "Delete Permanently…") { Task { await workspace.deleteSelectionForever() } }
                } else {
                    Menu {
                        ChatMoveMenuItems(chat: nil, facts: facts)
                    } label: {
                        glyph("folder")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Move to Folder")
                    .accessibilityLabel("Move to Folder")
                    action(
                        facts.pins ? "pin" : "pin.slash", facts.pins ? "Pin Chats" : "Unpin Chats",
                        run: workspace.togglePinSelection)
                    action(
                        facts.archives ? "archivebox" : "tray.and.arrow.up", facts.archives ? "Archive" : "Unarchive",
                        run: workspace.toggleArchiveSelection)
                    action("trash", "Delete Chats…") { Task { await workspace.trashSelection() } }
                }
                action("xmark", "Clear Selection") { workspace.selection.clear() }
            }
            .padding(.leading, Theme.Spacing.lg)
            .padding(.trailing, Theme.Spacing.xs)
            .frame(height: Theme.Size.aiChatSearchField)
            .background { Color.clear.frosted(in: Capsule()) }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    private func action(_ symbol: String, _ label: LocalizedStringKey, run: @escaping () -> Void) -> some View {
        Button(action: run) { glyph(symbol) }
            .buttonStyle(.plain)
            .help(label)
            .accessibilityLabel(label)
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(Theme.Typography.composerSymbol)
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(width: Theme.Size.chatSelectionButton, height: Theme.Size.chatSelectionButton)
            .contentShape(.rect)
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
