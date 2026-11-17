import Foundation

/// What the store screen browses: every macOS extension, Raycast's own order, and its fetch date.
struct ExtensionStoreCatalog: Sendable, Equatable {
    var entries: [ExtensionStoreEntry]
    /// Raycast's store listing, in its order; empty when that endpoint didn't answer.
    var featured: [String]
    var fetchedAt: Date
    /// False for the first entries a cold open shows while the rest download; never cached.
    var isComplete: Bool

    /// A day, from `fetchedAt`; a cache stamped in the future reads as stale, never as fresh forever.
    static let freshness: TimeInterval = 24 * 3600

    func isFresh(now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age < Self.freshness
    }

    /// The first copy of an id wins, so the catalog's own pages outrank the shelves' extra fetches.
    init(
        entries: [ExtensionStoreEntry], featured: [ExtensionStoreEntry] = [], fetchedAt: Date,
        isComplete: Bool
    ) {
        var seen: Set<String> = []
        var unique: [ExtensionStoreEntry] = []
        for entry in entries + featured where seen.insert(entry.id).inserted {
            unique.append(entry)
        }
        self.entries = unique
        var listed: Set<String> = []
        self.featured = featured.map(\.id).filter { listed.insert($0).inserted }
        self.fetchedAt = fetchedAt
        self.isComplete = isComplete
    }

    func entry(id: String) -> ExtensionStoreEntry? {
        entries.first { $0.id == id }
    }
}

/// `extension-store.json` in Caches: a trimmed catalog any build can read back, or ignore.
enum ExtensionStoreCacheFormat {
    static let version = 1

    private struct File: Codable {
        var version: Int?
        var fetchedAt: Double?
        var featured: [String]?
        var entries: [StoreLossy<CachedEntry>]?
    }

    /// Short keys keep three thousand entries near a megabyte; every one but `id` and `name` optional.
    private struct CachedEntry: Codable {
        var id: String
        var name: String
        var title: String?
        var summary: String?
        var author: String?
        var handle: String?
        var lightIcon: String?
        var darkIcon: String?
        var commands: [[String]]?
        var categories: [String]?
        var downloads: Int?
        var created: Double?
        var updated: Double?
        var isNew: Bool?
        var commit: String?

        init(_ entry: ExtensionStoreEntry) {
            id = entry.id
            name = entry.name
            title = entry.title
            summary = entry.summary.isEmpty ? nil : entry.summary
            author = entry.author
            handle = entry.handle
            lightIcon = entry.lightIcon?.absoluteString
            darkIcon = entry.darkIcon?.absoluteString
            commands = entry.commands.isEmpty ? nil : entry.commands.map { [$0.title, $0.summary] }
            categories = entry.categories.isEmpty ? nil : entry.categories
            downloads = entry.downloads
            created = entry.createdAt?.timeIntervalSince1970
            updated = entry.updatedAt?.timeIntervalSince1970
            isNew = entry.isNew ? true : nil
            commit = entry.commitSHA
        }

        var entry: ExtensionStoreEntry? {
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return ExtensionStoreEntry(
                id: id, name: name, title: title ?? name, summary: summary ?? "",
                author: author ?? handle ?? "", handle: handle ?? "",
                lightIcon: lightIcon.flatMap(URL.init(string:)),
                darkIcon: darkIcon.flatMap(URL.init(string:)),
                commands: (commands ?? []).compactMap { pair in
                    pair.first.map {
                        ExtensionStoreEntry.Command(title: $0, summary: pair.dropFirst().first ?? "")
                    }
                },
                categories: categories ?? [], downloads: max(0, downloads ?? 0),
                createdAt: created.map(Date.init(timeIntervalSince1970:)),
                updatedAt: updated.map(Date.init(timeIntervalSince1970:)),
                isNew: isNew ?? false, commitSHA: commit)
        }
    }

    static func encode(_ catalog: ExtensionStoreCatalog) throws -> Data {
        let file = File(
            version: version, fetchedAt: catalog.fetchedAt.timeIntervalSince1970,
            featured: catalog.featured,
            entries: catalog.entries.map { StoreLossy(value: CachedEntry($0)) })
        return try JSONEncoder().encode(file)
    }

    /// Nil for anything that isn't a catalog with entries; a later version's extra keys are ignored.
    static func decode(_ data: Data) -> ExtensionStoreCatalog? {
        guard let file = try? JSONDecoder().decode(File.self, from: data),
            let fetchedAt = file.fetchedAt
        else { return nil }
        let entries = (file.entries ?? []).compactMap { $0.value?.entry }
        guard !entries.isEmpty else { return nil }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ExtensionStoreCatalog(
            entries: entries, featured: (file.featured ?? []).compactMap { byID[$0] },
            fetchedAt: Date(timeIntervalSince1970: fetchedAt), isComplete: true)
    }
}

extension StoreLossy: Encodable where Value: Encodable {
    init(value: Value) {
        self.value = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
