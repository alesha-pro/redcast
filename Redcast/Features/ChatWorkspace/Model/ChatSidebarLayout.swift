import Foundation

/// Fork: the AI Chat sidebar's sections; each chat is listed exactly once.
struct ChatSidebarLayout: Equatable {
    struct FolderGroup: Equatable, Identifiable {
        let folder: ChatFolder
        let rows: [ChatTreeRow]
        /// Every chat filed here, a folded branch's included.
        let count: Int
        var id: UUID { folder.id }
    }

    struct DayGroup: Equatable, Identifiable {
        let title: String
        var rows: [ChatTreeRow]
        var id: String { title }
    }

    var pinned: [ChatTreeRow] = []
    var folders: [FolderGroup] = []
    var recent: [DayGroup] = []
    var archived: [ChatTreeRow] = []
    /// Search results, pinned first and flat; nil while nothing is typed.
    var results: [ChatTreeRow]?

    /// Pinned above everything, then folders, then Recent by day; archived chats only in Archived.
    init(
        conversations: [ChatConversation], workspace: ChatWorkspace, matching: Set<UUID>? = nil,
        dayTitle: (Date) -> String
    ) {
        let live = conversations.filter { !workspace.isTrashed($0.id) }
        let titles = Dictionary(live.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { first, _ in first })
        func origin(_ parent: UUID) -> ChatBranchOrigin? {
            if let title = titles[parent] { return ChatBranchOrigin(id: parent, title: title, opens: true) }
            guard workspace.isTrashed(parent) else { return nil }
            return ChatBranchOrigin(id: parent, title: workspace.placement(of: parent).deletedTitle ?? "", opens: false)
        }
        if let matching {
            results = ChatBranchTree.flatRows(
                live.filter { matching.contains($0.id) }.pinnedFirst,
                origin: { workspace.parentID(of: $0).flatMap(origin) })
            return
        }
        var pinnedChats: [ChatConversation] = []
        var archivedChats: [ChatConversation] = []
        var recentChats: [ChatConversation] = []
        var byFolder: [UUID: [ChatConversation]] = [:]
        for chat in live {
            if workspace.isArchived(chat.id) {
                archivedChats.append(chat)
            } else if chat.isPinned {
                pinnedChats.append(chat)
            } else if let folder = workspace.folderID(of: chat.id) {
                byFolder[folder, default: []].append(chat)
            } else {
                recentChats.append(chat)
            }
        }
        func trees(_ chats: [ChatConversation]) -> [ChatBranchTree.Tree] {
            ChatBranchTree.trees(
                chats, parent: workspace.parentID(of:), isFolded: workspace.foldsBranches(of:), origin: origin)
        }
        pinned = trees(pinnedChats).flatMap(\.rows)
        archived = trees(archivedChats).flatMap(\.rows)
        folders = workspace.folders.map { folder in
            let chats = byFolder[folder.id] ?? []
            return FolderGroup(folder: folder, rows: trees(chats).flatMap(\.rows), count: chats.count)
        }
        for tree in trees(recentChats) {
            let title = dayTitle(tree.newest.updatedAt)
            if recent.last?.title == title {
                recent[recent.count - 1].rows += tree.rows
            } else {
                recent.append(DayGroup(title: title, rows: tree.rows))
            }
        }
    }

    /// What ⌘1…⌘0 reach: the rows on screen from the top, past folded folders, branches and Archived.
    var shortcutOrder: [UUID] {
        if let results { return results.map(\.id) }
        return (pinned + folders.filter { !$0.folder.isCollapsed }.flatMap(\.rows)
            + recent.flatMap(\.rows)).map(\.id)
    }

    /// The rows a click, ⇧ and ⌘A select among: ⌘'s rows, then Archived while it is open.
    func selectableOrder(showingArchived: Bool) -> [UUID] {
        guard results == nil, showingArchived else { return shortcutOrder }
        return shortcutOrder + archived.map(\.id)
    }

    /// Clipboard's day buckets, restated here so the model needs no view to name a day.
    static func dayTitle(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return String(localized: "This Week")
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return String(localized: "This Month") }
        return String(localized: "Earlier")
    }

    var isEmpty: Bool {
        pinned.isEmpty && folders.isEmpty && recent.isEmpty && archived.isEmpty
            && (results?.isEmpty ?? true)
    }}

/// Fork: ⌘1–⌘9 and ⌘0 open the first ten rows, as Raycast's sidebar does.
enum ChatShortcutIndex {
    static let digits: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    static func chat(forDigit digit: Character, in order: [UUID]) -> UUID? {
        guard let index = digits.firstIndex(of: digit), index < order.count else { return nil }
        return order[index]
    }

    /// The badge a row shows while ⌘ is held; nil past the tenth.
    static func badge(for chat: UUID, in order: [UUID]) -> String? {
        guard let index = order.prefix(digits.count).firstIndex(of: chat) else { return nil }
        return String(digits[index])
    }
}
