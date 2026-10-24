import Foundation
import Observation

/// Fork: folders, archive, Recently Deleted, branches and edits, for AI Chat's window.
@MainActor
@Observable
final class ChatWorkspaceCoordinator {
    let store: ChatWorkspaceStore
    let settings: ChatWorkspaceSettings
    let history: ChatHistoryStore
    let chats: AIChatSurfacesState
    @ObservationIgnored weak var host: (any ChatWorkspaceHost)?
    @ObservationIgnored weak var settingsSource: (any ChatSettingsSource)?
    /// The window's split view answers this while it is open.
    @ObservationIgnored var toggleSettingsSidebar: (() -> Void)?
    /// While ⌘ is down the first ten rows show their digits.
    var showsShortcuts = false
    /// The question ↑ brought back into the composer; one at a time, the window's.
    private(set) var recall: ChatRecall?
    /// The folder whose editor is open; nil for none, a fresh id while creating one.
    var editingFolder: ChatFolder?
    var isCreatingFolder = false
    /// A chat whose title the sidebar is renaming, set by a double click or the menu.
    var renaming: UUID?

    init(
        store: ChatWorkspaceStore, settings: ChatWorkspaceSettings, history: ChatHistoryStore,
        chats: AIChatSurfacesState
    ) {
        self.store = store
        self.settings = settings
        self.history = history
        self.chats = chats
    }

    var workspace: ChatWorkspace { store.workspace }

    // MARK: - Lifecycle

    /// Before the history loads, so Recently Deleted is hidden from its first list on.
    func prepare() {
        store.load()
        history.isHidden = { [weak store] id in store?.workspace.isTrashed(id) == true }
    }

    /// As history loads and as the window opens: stale entries, expired deletions, idle chats.
    func tidy(now: Date = Date()) {
        guard history.isAvailable else { return }
        store.load()
        let saved = Set(history.conversations.map(\.id)).union(chats.live.map(\.session.id))
        for id in workspace.expired(at: now) { eraseForever(id) }
        store.change { $0.prune(keeping: saved) }
        let sparing = Set(chats.live.map(\.session.id))
        let idle = settings.autoArchive.chatsToArchive(
            history.conversations, workspace: workspace, now: now, sparing: sparing)
        guard !idle.isEmpty else { return }
        store.change { workspace in
            for id in idle { workspace.archive(id, at: now) }
        }
    }

    func close() {
        recall = nil
        store.close()
    }

    var trashedIDs: Set<UUID> { Set(workspace.trashed.map(\.id)) }

    // MARK: - Folders

    func folder(of chat: UUID) -> ChatFolder? { workspace.folder(id: workspace.folderID(of: chat)) }

    @discardableResult
    func createFolder(
        named name: String, hue: RaycastHue, symbol: String, instructions: String?, agentID: UUID?
    ) -> ChatFolder? {
        var created: ChatFolder?
        store.change { workspace in
            created = workspace.createFolder(named: name, hue: hue, symbol: symbol)
            if let id = created?.id {
                workspace.updateFolder(id) {
                    $0.instructions = instructions
                    $0.agentID = agentID
                }
            }
        }
        return created
    }

    func updateFolder(_ folder: ChatFolder) {
        store.change { workspace in
            workspace.updateFolder(folder.id) {
                $0.name = folder.name
                $0.color = folder.color
                $0.symbol = folder.symbol
                $0.instructions = folder.instructions
                $0.agentID = folder.agentID
            }
        }
    }

    func toggleCollapsed(_ id: UUID) {
        store.change { workspace in workspace.updateFolder(id) { $0.isCollapsed.toggle() } }
    }

    /// Its chats return to Recent, as the confirmation says; nothing in it is deleted.
    func deleteFolder(_ folder: ChatFolder) async {
        guard let host,
            await host.confirm(
                title: String(localized: "Delete “\(folder.name)”?"),
                message: String(localized: "Its chats move back to Recent. No chat is deleted."),
                symbol: "folder", confirmTitle: String(localized: "Delete Folder"))
        else { return }
        store.change { $0.deleteFolder(folder.id) }
    }

    /// A new chat filed in the folder from the start, on the folder's agent when it names one.
    func newChat(in folder: ChatFolder) {
        host?.newChat(agentID: folder.agentID)
        store.change { $0.move(chats.window.session.id, to: folder.id) }
    }

    // MARK: - Moving chats

    /// A folder lists only unpinned chats, so filing one unpins it, as dropping it there does.
    func move(_ chat: UUID, to folder: UUID?) {
        if history.conversation(id: chat)?.isPinned == true { history.setPinned(false, id: chat) }
        store.change { $0.move(chat, to: folder) }
    }

    /// Dropped on Pinned: pinned, and out of Archived.
    func pin(_ chat: UUID) {
        history.setPinned(true, id: chat)
        store.change { $0.unarchive(chat) }
    }

    func archive(_ chat: UUID, now: Date = Date()) {
        if history.conversation(id: chat)?.isPinned == true { history.setPinned(false, id: chat) }
        store.change { $0.archive(chat, at: now) }
    }

    func unarchive(_ chat: UUID) {
        store.change { $0.unarchive(chat) }
    }

    // MARK: - Recently Deleted

    /// Out of every list at once, kept 60 days; a reply still running stops and saves first.
    func trash(_ id: UUID, now: Date = Date()) {
        guard let conversation = history.conversation(id: id) else { return }
        if conversation.isPinned { history.setPinned(false, id: id) }
        store.change { $0.trash(id, title: conversation.displayTitle, at: now) }
        chats.holder(of: id)?.startNewChat()
        history.load()
        if recall?.chatID == id { recall = nil }
    }

    func restore(_ id: UUID) {
        store.change { $0.restore(id) }
        history.load()
    }

    func deleteForever(_ id: UUID) async {
        let title = workspace.placement(of: id).deletedTitle ?? String(localized: "This chat")
        guard let host,
            await host.confirm(
                title: String(localized: "Delete chat?"),
                message: String(localized: "“\(title)” will be removed. This can't be undone."),
                symbol: "trash", confirmTitle: String(localized: "Delete"))
        else { return }
        eraseForever(id)
    }

    func emptyTrash() async {
        let doomed = workspace.trashed.map(\.id)
        guard !doomed.isEmpty, let host,
            await host.confirm(
                title: String(localized: "Empty Recently Deleted?"),
                message: String(localized: "\(doomed.count) chats will be removed. This can't be undone."),
                symbol: "trash", confirmTitle: String(localized: "Delete All"))
        else { return }
        for id in doomed { eraseForever(id) }
    }

    private func eraseForever(_ id: UUID) {
        history.remove(id: id)
        host?.forgetChat(id: id)
        store.change { $0.forget(id) }
    }

    // MARK: - Branches

    /// A new chat with the history up to the message, filed and asked as the original was.
    @discardableResult
    func branch(_ chatID: UUID, through messageID: UUID? = nil) -> UUID? {
        guard let session = chats.holder(of: chatID)?.session ?? history.session(id: chatID),
            let through = messageID ?? session.messages.last(where: { $0.state != .streaming })?.id,
            let messages = ChatBranch.messages(of: session.messages, through: through)
        else { return nil }
        let branch = ChatSession(messages: messages, model: session.model)
        history.save(branch)
        let title = history.conversation(id: chatID)?.displayTitle ?? session.title
        history.rename(id: branch.id, to: String(localized: "\(title) (Branch)"))
        store.change { $0.copyPlacement(from: chatID, to: branch.id) }
        if let agent = host?.agentID(ofChat: chatID) { host?.bindAgent(agent, toChat: branch.id) }
        host?.openChat(id: branch.id)
        return branch.id
    }

    // MARK: - Editing a sent question

    /// ↑ from an empty composer, or Edit on a question: its text comes back to be sent again.
    @discardableResult
    func beginEditing(_ messageID: UUID? = nil, in chat: AIChatState) -> Bool {
        guard !chat.isStreaming else { return false }
        let draft = recall?.chatID == chat.session.id ? recall?.draft ?? chat.draft : chat.draft
        guard
            let started = ChatRecall(
                editing: messageID, in: chat.session.messages, chatID: chat.session.id, draft: draft)
        else { return false }
        recall = started
        chat.draft = started.text
        return true
    }

    /// ↑ and ↓ while a recalled question is unedited; past the newest the draft comes back.
    func stepRecall(_ direction: Int, in chat: AIChatState) -> Bool {
        guard ChatRecall.arrowsStep(composer: chat.draft, recall: activeRecall(in: chat)) else {
            return false
        }
        guard var current = activeRecall(in: chat) else {
            return direction < 0 && beginEditing(in: chat)
        }
        guard current.step(direction, in: chat.session.messages) else {
            cancelEditing(in: chat)
            return true
        }
        recall = current
        chat.draft = current.text
        return true
    }

    /// Esc: the draft from before, and the transcript as it was.
    @discardableResult
    func cancelEditing(in chat: AIChatState) -> Bool {
        guard let current = activeRecall(in: chat) else { return false }
        recall = nil
        chat.draft = current.draft
        return true
    }

    func editingMessageID(in chat: AIChatState) -> UUID? { activeRecall(in: chat)?.messageID }

    /// Called just before a send: an edited question replaces itself and every later message.
    func applyEdit(in chat: AIChatState) {
        guard let current = activeRecall(in: chat) else { return }
        recall = nil
        guard !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let kept = ChatRecall.keptCount(editing: current.messageID, in: chat.session.messages)
        else { return }
        chat.rewind(keeping: kept)
    }

    private func activeRecall(in chat: AIChatState) -> ChatRecall? {
        recall?.chatID == chat.session.id ? recall : nil
    }

    // MARK: - Per chat

    func setInstructions(_ text: String, of chat: UUID) {
        store.change { $0.setInstructions(text, of: chat) }
    }

    func setCreativity(_ creativity: ChatCreativity?, of chat: UUID) {
        store.change { $0.setCreativity(creativity, of: chat) }
    }

    /// The app's prompt, then the folder's instructions, then the chat's own.
    func instructions(for chat: UUID, base: String?) -> String? {
        let placement = workspace.placement(of: chat)
        let folder = folder(of: chat)
        return ChatInstructions.compose(
            base: base, folderName: folder?.name, folder: folder?.instructions,
            chat: placement.instructions)
    }

    func temperature(for chat: UUID) -> Double? {
        workspace.placement(of: chat).creativity?.temperature
    }

    /// The sidebar's rows as they stand; search narrows to titles and message text.
    func layout(matching: Set<UUID>?) -> ChatSidebarLayout {
        ChatSidebarLayout(
            conversations: history.conversations, workspace: workspace, matching: matching,
            dayTitle: { ChatSidebarLayout.dayTitle(for: $0) })
    }
}
