import Foundation

/// Fork: the sidebar's multi-selection and what it does to every chat in it at once.
extension ChatWorkspaceCoordinator {
    /// The rows a selection is made among, top to bottom: the chats, or Recently Deleted's.
    func selectionOrder(_ layout: ChatSidebarLayout, inTrash: Bool) -> [UUID] {
        inTrash ? trashOrder : layout.selectableOrder(showingArchived: showsArchived)
    }

    /// Every selectable row on screen; once this changes under a selection, the selection goes.
    func selectionContents(_ layout: ChatSidebarLayout) -> Set<UUID> {
        Set(layout.selectableOrder(showingArchived: showsArchived)).union(trashOrder)
    }

    private var trashOrder: [UUID] {
        showsDeleted ? workspace.trashed.map(\.id) : []
    }

    /// A row's click; true when it should open, as a plain click does.
    @discardableResult
    func click(_ id: UUID, _ click: ChatSelection.Click, inTrash: Bool = false) -> Bool {
        clickKind = .plain
        let layout = sidebarLayout
        let opens = selection.click(
            id, click, in: selectionOrder(layout, inTrash: inTrash),
            open: inTrash ? nil : chats.window.session.id, contents: selectionContents(layout))
        return opens
    }

    /// ⌘A: every chat the list shows; in Recently Deleted's own selection, every deleted one.
    func selectAll() {
        let layout = sidebarLayout
        selection.selectAll(
            selectionOrder(layout, inTrash: selectionIsInTrash), contents: selectionContents(layout))
    }

    var selectionIsInTrash: Bool {
        !selection.isEmpty && selection.ids.isSubset(of: trashedIDs)
    }

    /// The selection in the list's order, so a drag and a bulk action keep what is on screen.
    var selectedIDs: [UUID] {
        let layout = sidebarLayout
        return selection.ordered(in: selectionOrder(layout, inTrash: selectionIsInTrash))
    }

    var selectionFacts: ChatBulkFacts {
        ChatBulkFacts(selectedIDs, conversations: history.conversations, workspace: workspace)
    }

    /// A drag from a selected row carries the whole selection, from any other row just that chat.
    func dragged(_ id: UUID) -> [UUID] {
        selection.contains(id) ? selectedIDs : [id]
    }

    // MARK: - Bulk actions; each one clears the selection it used

    func moveSelection(to folder: UUID?) {
        let ids = selectedIDs
        selection.clear()
        move(ids, to: folder)
    }

    func moveSelectionToNewFolder() {
        let ids = selectedIDs
        guard
            let folder = createFolder(
                named: String(localized: "New Folder"), hue: ChatFolder.nextHue(after: workspace.folders),
                symbol: ChatFolder.symbols[0], instructions: nil, agentID: nil)
        else { return }
        selection.clear()
        move(ids, to: folder.id)
        editingFolder = folder
    }

    /// Only the filed chats leave their folders; the rest stay where they are.
    func removeSelectionFromFolders() {
        let ids = selectedIDs.filter { workspace.folderID(of: $0) != nil }
        selection.clear()
        move(ids, to: nil)
    }

    func togglePinSelection() {
        let facts = selectionFacts
        selection.clear()
        if facts.pins {
            pin(facts.ids)
        } else {
            for id in facts.ids { history.setPinned(false, id: id) }
        }
    }

    func toggleArchiveSelection() {
        let facts = selectionFacts
        selection.clear()
        if facts.archives {
            archive(facts.ids)
        } else {
            unarchive(facts.ids)
        }
    }

    /// To Recently Deleted after one question naming how many; nothing is erased.
    func trashSelection() async {
        let ids = selectedIDs
        guard !ids.isEmpty, let host,
            await host.confirm(
                title: String(localized: "Delete \(ids.count) chats?"),
                message: String(localized: "They stay in Recently Deleted for 60 days and can be restored."),
                symbol: "trash", confirmTitle: String(localized: "Delete"))
        else { return }
        selection.clear()
        trash(ids)
    }

    func restoreSelection() {
        let ids = selectedIDs
        selection.clear()
        restore(ids)
    }

    func deleteSelectionForever() async {
        let ids = selectedIDs
        await deleteForever(ids)
        if !workspace.trashed.contains(where: { ids.contains($0.id) }) { selection.clear() }
    }

    /// ⌫ with a selection: Recently Deleted's go for good, other chats to Recently Deleted.
    func deleteSelection() async {
        if selectionIsInTrash {
            await deleteSelectionForever()
        } else {
            await trashSelection()
        }
    }

    func copySelection() {
        let ids = selectedIDs
        selection.clear()
        host?.copyChats(ids: ids)
    }
}
