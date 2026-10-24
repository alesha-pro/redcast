import Foundation

/// Fork: what a saved chat carries beyond its transcript: where it is filed and how it is asked.
struct ChatPlacement: Equatable, Sendable {
    var folderID: UUID?
    /// The chat's own Additional Instructions, sent last in its system prompt.
    var instructions: String?
    var creativity: ChatCreativity?
    var archivedAt: Date?
    /// Set once the chat is in Recently Deleted; purged `ChatWorkspace.trashLifetime` later.
    var deletedAt: Date?
    /// The title it had, so Recently Deleted can list it while the history hides it.
    var deletedTitle: String?
    var unknown: [String: JSONValue] = [:]

    /// An entry with nothing left in it is dropped, so the file only names chats it says something of.
    var isEmpty: Bool {
        folderID == nil && instructions == nil && creativity == nil && archivedAt == nil
            && deletedAt == nil && unknown.isEmpty
    }
}

/// Fork: folders and every chat's placement, as one tolerant document beside the chat history.
struct ChatWorkspace: Equatable, Sendable {
    static let version = 1
    /// Raycast keeps Recently Deleted for 60 days.
    static let trashLifetime: TimeInterval = 60 * 24 * 60 * 60

    private(set) var folders: [ChatFolder] = []
    private(set) var placements: [UUID: ChatPlacement] = [:]
    /// Top-level fields a newer build wrote.
    var unknown: [String: JSONValue] = [:]

    init(folders: [ChatFolder] = [], placements: [UUID: ChatPlacement] = [:]) {
        self.folders = folders
        self.placements = placements
    }

    // MARK: - Folders

    func folder(id: UUID?) -> ChatFolder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    @discardableResult
    mutating func createFolder(
        named name: String, hue: RaycastHue? = nil, symbol: String? = nil, id: UUID = UUID()
    ) -> ChatFolder? {
        guard let name = ChatFolder.cleanName(name) else { return nil }
        let folder = ChatFolder(
            id: id, name: name, color: hue ?? ChatFolder.nextHue(after: folders),
            symbol: symbol ?? ChatFolder.symbols[0])
        folders.append(folder)
        return folder
    }

    /// Every edit goes through here; a blank name keeps the old one.
    mutating func updateFolder(_ id: UUID, _ change: (inout ChatFolder) -> Void) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        var folder = folders[index]
        let name = folder.name
        change(&folder)
        folder.name = ChatFolder.cleanName(folder.name) ?? name
        folder.instructions = Self.cleanText(folder.instructions)
        folders[index] = folder
    }

    /// The folder goes, its chats go back to Recent; deleting a folder never deletes a chat.
    mutating func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for (chat, placement) in placements where placement.folderID == id {
            update(chat) { $0.folderID = nil }
        }
    }

    // MARK: - Chats

    func placement(of chat: UUID) -> ChatPlacement { placements[chat] ?? ChatPlacement() }

    func folderID(of chat: UUID) -> UUID? {
        guard let id = placements[chat]?.folderID, folder(id: id) != nil else { return nil }
        return id
    }

    func isArchived(_ chat: UUID) -> Bool { placements[chat]?.archivedAt != nil }
    func isTrashed(_ chat: UUID) -> Bool { placements[chat]?.deletedAt != nil }

    /// Nil is Recent; an unknown folder leaves the chat where it was.
    mutating func move(_ chat: UUID, to folderID: UUID?) {
        guard folderID == nil || folder(id: folderID) != nil else { return }
        update(chat) {
            $0.folderID = folderID
            $0.archivedAt = nil
        }
    }

    mutating func setInstructions(_ text: String?, of chat: UUID) {
        update(chat) { $0.instructions = Self.cleanText(text) }
    }

    mutating func setCreativity(_ creativity: ChatCreativity?, of chat: UUID) {
        update(chat) { $0.creativity = creativity }
    }

    mutating func archive(_ chat: UUID, at date: Date) {
        update(chat) { $0.archivedAt = date }
    }

    mutating func unarchive(_ chat: UUID) {
        update(chat) { $0.archivedAt = nil }
    }

    mutating func trash(_ chat: UUID, title: String, at date: Date) {
        update(chat) {
            $0.deletedAt = date
            $0.deletedTitle = title
        }
    }

    mutating func restore(_ chat: UUID) {
        update(chat) {
            $0.deletedAt = nil
            $0.deletedTitle = nil
        }
    }

    /// A chat deleted for good takes its entry with it.
    mutating func forget(_ chat: UUID) {
        placements[chat] = nil
    }

    /// A branch starts where its source is filed, asked the same way, but never archived or deleted.
    mutating func copyPlacement(from source: UUID, to branch: UUID) {
        var placement = placement(of: source)
        placement.archivedAt = nil
        placement.deletedAt = nil
        placement.deletedTitle = nil
        placements[branch] = placement.isEmpty ? nil : placement
    }

    /// Recently Deleted, newest first.
    var trashed: [(id: UUID, title: String, deletedAt: Date)] {
        placements.compactMap { id, placement in
            placement.deletedAt.map { (id, placement.deletedTitle ?? "", $0) }
        }
        .sorted { $0.deletedAt > $1.deletedAt }
    }

    /// The chats Recently Deleted has kept for its whole lifetime.
    func expired(at now: Date) -> [UUID] {
        placements.compactMap { id, placement in
            guard let deleted = placement.deletedAt,
                now.timeIntervalSince(deleted) >= Self.trashLifetime
            else { return nil }
            return id
        }
    }

    /// Entries for chats the history no longer has; deleted ones stay until their purge.
    mutating func prune(keeping saved: Set<UUID>) {
        placements = placements.filter { saved.contains($0.key) || $0.value.deletedAt != nil }
    }

    private mutating func update(_ chat: UUID, _ change: (inout ChatPlacement) -> Void) {
        var placement = placements[chat] ?? ChatPlacement()
        change(&placement)
        placements[chat] = placement.isEmpty ? nil : placement
    }

    private static func cleanText(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(text.prefix(instructionsLimit))
    }

    static let instructionsLimit = 8_000
}

// MARK: - The file

extension ChatWorkspace {
    private enum Key {
        static let version = "version", folders = "folders", chats = "chats"
        static let folder = "folder", instructions = "instructions", creativity = "creativity"
        static let archived = "archivedAt", deleted = "deletedAt", deletedTitle = "deletedTitle"
        static let top: Set<String> = [version, folders, chats]
        static let chat: Set<String> = [folder, instructions, creativity, archived, deleted, deletedTitle]
    }

    /// Whatever parses is kept: a bad folder or chat is dropped alone, never the whole file.
    init(data: Data) {
        guard let object = JSONValue(data: data)?.objectValue else { return }
        folders = (object[Key.folders]?.arrayValue ?? []).compactMap(ChatFolder.init(json:))
        var seen = Set<UUID>()
        folders = folders.filter { seen.insert($0.id).inserted }
        for (key, value) in object[Key.chats]?.objectValue ?? [:] {
            guard let id = UUID(uuidString: key), let fields = value.objectValue else { continue }
            var placement = ChatPlacement()
            placement.folderID = fields[Key.folder]?.stringValue.flatMap(UUID.init(uuidString:))
            placement.instructions = Self.cleanText(fields[Key.instructions]?.stringValue)
            placement.creativity = fields[Key.creativity]?.stringValue.flatMap(ChatCreativity.init(rawValue:))
            placement.archivedAt = fields[Key.archived]?.workspaceDate
            placement.deletedAt = fields[Key.deleted]?.workspaceDate
            placement.deletedTitle = fields[Key.deletedTitle]?.stringValue
            placement.unknown = fields.filter { !Key.chat.contains($0.key) }
            if !placement.isEmpty { placements[id] = placement }
        }
        unknown = object.filter { !Key.top.contains($0.key) }
    }

    var data: Data {
        var object = unknown
        object[Key.version] = .number(Double(Self.version))
        object[Key.folders] = .array(folders.map(\.json))
        var chats: [String: JSONValue] = [:]
        for (id, placement) in placements {
            var fields = placement.unknown
            if let folder = placement.folderID { fields[Key.folder] = .string(folder.uuidString) }
            if let text = placement.instructions { fields[Key.instructions] = .string(text) }
            if let creativity = placement.creativity { fields[Key.creativity] = .string(creativity.rawValue) }
            if let date = placement.archivedAt { fields[Key.archived] = .number(date.timeIntervalSince1970) }
            if let date = placement.deletedAt { fields[Key.deleted] = .number(date.timeIntervalSince1970) }
            if let title = placement.deletedTitle { fields[Key.deletedTitle] = .string(title) }
            chats[id.uuidString] = .object(fields)
        }
        object[Key.chats] = .object(chats)
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        return (try? JSONSerialization.data(withJSONObject: JSONValue.object(object).jsonObject, options: options))
            ?? Data()
    }
}

extension JSONValue {
    /// Seconds since 1970, the unit the chat history stores its own dates in.
    fileprivate var workspaceDate: Date? {
        guard case .number(let seconds) = self, seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
