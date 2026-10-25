import Foundation

/// Fork: what a selection of chats offers: one action for all, worded for the chats in it.
struct ChatBulkFacts: Equatable, Sendable {
    let ids: [UUID]
    /// Pin unless every chat is pinned already; then Unpin.
    let pins: Bool
    /// Archive unless every chat is archived already; then Unarchive.
    let archives: Bool
    let anyFiled: Bool
    /// The folder every chat is in, for Move to Folder's check; nil when they differ or none is filed.
    let sharedFolder: UUID?

    init(_ ids: [UUID], conversations: [ChatConversation], workspace: ChatWorkspace) {
        self.ids = ids
        let pinned = Set(conversations.filter(\.isPinned).map(\.id))
        pins = !ids.allSatisfy(pinned.contains)
        archives = !ids.allSatisfy(workspace.isArchived)
        let folders = Set(ids.map(workspace.folderID(of:)))
        anyFiled = folders.contains { $0 != nil }
        sharedFolder = folders.count == 1 ? folders.first.flatMap { $0 } : nil
    }
}

/// Fork: a selection's edits, each one change to the document however many chats it names.
extension ChatWorkspace {
    /// Nil is Recent; a branch moves alone, so its parent and siblings stay where they are.
    mutating func move(_ chats: [UUID], to folderID: UUID?) {
        for chat in chats { move(chat, to: folderID) }
    }

    mutating func archive(_ chats: [UUID], at date: Date) {
        for chat in chats { archive(chat, at: date) }
    }

    mutating func unarchive(_ chats: [UUID]) {
        for chat in chats { unarchive(chat) }
    }

    /// Each keeps its title for Recently Deleted; a parent's branches are never taken with it.
    mutating func trash(_ chats: [(id: UUID, title: String)], at date: Date) {
        for chat in chats { trash(chat.id, title: chat.title, at: date) }
    }

    mutating func restore(_ chats: [UUID]) {
        for chat in chats { restore(chat) }
    }
}
