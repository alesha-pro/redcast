import Foundation

/// A list the store can be browsed by: one of its orderings, or one category.
enum ExtensionStoreBrowse: Hashable, Sendable {
    case featured
    case popular
    case recentlyUpdated
    case new
    case category(String)

    /// A category is the store's own word, so it is shown as the store spells it.
    var title: String {
        switch self {
        case .featured: String(localized: "Featured", comment: "Extension Store: Raycast's own picks")
        case .popular: String(localized: "Popular", comment: "Extension Store: the most installed")
        case .recentlyUpdated: String(localized: "Recently Updated")
        case .new: String(localized: "New", comment: "Extension Store: extensions published lately")
        case .category(let name): name
        }
    }

    /// Cheap and stable, for row identity; a category's own name can't collide with a fixed list.
    var key: String {
        switch self {
        case .featured: "featured"
        case .popular: "popular"
        case .recentlyUpdated: "recently-updated"
        case .new: "new"
        case .category(let name): "category:" + name
        }
    }
}

/// A run of rows under one header.
enum ExtensionStoreSection: Hashable, Sendable {
    case shelf(ExtensionStoreBrowse)
    case categories
    /// What a query found, or the whole of one browse list.
    case results

    var title: String {
        switch self {
        case .shelf(let browse): browse.title
        case .categories: String(localized: "Categories")
        case .results: String(localized: "Results")
        }
    }

    var key: String {
        switch self {
        case .shelf(let browse): browse.key
        case .categories: "categories"
        case .results: "results"
        }
    }
}

/// One selectable row: an extension, or a way into one of the lists.
struct ExtensionStoreRow: Identifiable, Hashable, Sendable {
    enum Item: Hashable, Sendable {
        case entry(ExtensionStoreEntry)
        /// "Show All" under a shelf, or a category; `count` is how many it lists.
        case browse(ExtensionStoreBrowse, count: Int)
    }

    let section: ExtensionStoreSection
    let item: Item

    /// Per section, since one extension can sit on two shelves.
    var id: String {
        switch item {
        case .entry(let entry): section.key + "/" + entry.id
        case .browse(let browse, _): section.key + "/browse/" + browse.key
        }
    }

    var entry: ExtensionStoreEntry? {
        if case .entry(let entry) = item { return entry }
        return nil
    }
}

/// How the store is laid out with nothing typed, and what each list holds in full.
enum ExtensionStoreShelves {
    /// Rows a shelf shows before its "Show All".
    static let shelfSize = 6
    /// How recently published counts as new, alongside the store's own `is_new`.
    static let newSpan: TimeInterval = 14 * 24 * 3600

    static func isNew(_ entry: ExtensionStoreEntry, now: Date) -> Bool {
        if entry.isNew { return true }
        guard let created = entry.createdAt else { return false }
        return now.timeIntervalSince(created) < newSpan
    }

    /// The four shelves, each skipping what one above it showed, then every category.
    static func discover(_ catalog: ExtensionStoreCatalog, now: Date) -> [ExtensionStoreRow] {
        var rows: [ExtensionStoreRow] = []
        var shown: Set<String> = []
        // A cold open's first entries are a fraction of the store, so only their order means anything.
        let shelves: [ExtensionStoreBrowse] =
            catalog.isComplete ? [.featured, .popular, .recentlyUpdated, .new] : [.featured, .popular]
        for browse in shelves {
            let all = listing(browse, in: catalog, now: now)
            let shelf = all.filter { !shown.contains($0.id) }.prefix(shelfSize)
            guard !shelf.isEmpty else { continue }
            shown.formUnion(shelf.map(\.id))
            rows += shelf.map { ExtensionStoreRow(section: .shelf(browse), item: .entry($0)) }
            if all.count > shelf.count {
                rows.append(
                    ExtensionStoreRow(section: .shelf(browse), item: .browse(browse, count: all.count)))
            }
        }
        guard catalog.isComplete else { return rows }
        rows += categories(in: catalog).map {
            ExtensionStoreRow(section: .categories, item: .browse(.category($0.name), count: $0.count))
        }
        return rows
    }

    /// One list in full, in its own order.
    static func listing(
        _ browse: ExtensionStoreBrowse, in catalog: ExtensionStoreCatalog, now: Date
    ) -> [ExtensionStoreEntry] {
        switch browse {
        case .featured:
            let byID = Dictionary(
                catalog.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return catalog.featured.compactMap { byID[$0] }
        case .popular:
            return byDownloads(catalog.entries)
        case .recentlyUpdated:
            return catalog.entries.filter { $0.updatedAt != nil }.sorted {
                ordered($0.updatedAt, $1.updatedAt, $0, $1)
            }
        case .new:
            return catalog.entries.filter { isNew($0, now: now) }.sorted {
                ordered($0.createdAt, $1.createdAt, $0, $1)
            }
        case .category(let name):
            return byDownloads(catalog.entries.filter { $0.categories.contains(name) })
        }
    }

    /// Largest first, then by name, so two equal categories keep one order across loads.
    static func categories(in catalog: ExtensionStoreCatalog) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in catalog.entries {
            for category in Set(entry.categories) { counts[category, default: 0] += 1 }
        }
        return counts.map { (name: $0.key, count: $0.value) }.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name
        }
    }

    static func byDownloads(_ entries: [ExtensionStoreEntry]) -> [ExtensionStoreEntry] {
        entries.sorted {
            $0.downloads != $1.downloads ? $0.downloads > $1.downloads : tieBreak($0, $1)
        }
    }

    /// Newest first; equal dates fall back to downloads, then the title.
    private static func ordered(
        _ lhs: Date?, _ rhs: Date?, _ a: ExtensionStoreEntry, _ b: ExtensionStoreEntry
    ) -> Bool {
        let left = lhs ?? .distantPast
        let right = rhs ?? .distantPast
        if left != right { return left > right }
        if a.downloads != b.downloads { return a.downloads > b.downloads }
        return tieBreak(a, b)
    }

    private static func tieBreak(_ a: ExtensionStoreEntry, _ b: ExtensionStoreEntry) -> Bool {
        let order = a.title.localizedCaseInsensitiveCompare(b.title)
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }
}
