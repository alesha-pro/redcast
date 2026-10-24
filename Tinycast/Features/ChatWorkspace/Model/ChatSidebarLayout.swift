import Foundation

/// Fork: the AI Chat sidebar's sections; each chat is listed exactly once.
struct ChatSidebarLayout: Equatable {
    struct FolderGroup: Equatable, Identifiable {
        let folder: ChatFolder
        let chats: [ChatConversation]
        var id: UUID { folder.id }
    }

    struct DayGroup: Equatable, Identifiable {
        let title: String
        var chats: [ChatConversation]
        var id: String { title }
    }

    var pinned: [ChatConversation] = []
    var folders: [FolderGroup] = []
    var recent: [DayGroup] = []
    var archived: [ChatConversation] = []
    /// Search results, pinned first; nil while nothing is typed.
    var results: [ChatConversation]?

    /// Pinned above everything, then folders, then Recent by day; archived chats only in Archived.
    init(
        conversations: [ChatConversation], workspace: ChatWorkspace, matching: Set<UUID>? = nil,
        dayTitle: (Date) -> String
    ) {
        let live = conversations.filter { !workspace.isTrashed($0.id) }
        if let matching {
            results = live.filter { matching.contains($0.id) }.pinnedFirst
            return
        }
        var byFolder: [UUID: [ChatConversation]] = [:]
        for chat in live {
            if workspace.isArchived(chat.id) {
                archived.append(chat)
            } else if chat.isPinned {
                pinned.append(chat)
            } else if let folder = workspace.folderID(of: chat.id) {
                byFolder[folder, default: []].append(chat)
            } else {
                let title = dayTitle(chat.updatedAt)
                if recent.last?.title == title {
                    recent[recent.count - 1].chats.append(chat)
                } else {
                    recent.append(DayGroup(title: title, chats: [chat]))
                }
            }
        }
        folders = workspace.folders.map { FolderGroup(folder: $0, chats: byFolder[$0.id] ?? []) }
    }

    /// What ⌘1…⌘0 reach: the rows on screen from the top, skipping folded folders and Archived.
    var shortcutOrder: [UUID] {
        if let results { return results.map(\.id) }
        return (pinned + folders.filter { !$0.folder.isCollapsed }.flatMap(\.chats)
            + recent.flatMap(\.chats)).map(\.id)
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
    }
}

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
