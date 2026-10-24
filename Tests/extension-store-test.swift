import Foundation

/// The Extension Store's decoding, cache, shelves, categories, search and install state, offline.
@main
@MainActor
struct ExtensionStoreScreenTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static let fixtures = URL(filePath: "Tests/extension-store-fixtures", directoryHint: .isDirectory)
    static let now = Date(timeIntervalSince1970: 1_792_833_951)

    static func fixture(_ name: String) -> Data {
        (try? Data(contentsOf: fixtures.appending(path: name))) ?? Data()
    }

    static func main() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "extension-store-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        theCatalogEndpointDecodes()
        thePopularEndpointDecodes()
        theStoreListingDecodes()
        aHostilePageSkipsOnlyItsBadEntries()
        somethingThatIsNotAPageThrows()
        endpointsAreBuiltAsProbed()
        theCatalogKeepsTheFirstCopyOfAnID()
        theCacheRoundTrips()
        theCacheToleratesOtherBuilds()
        try theCacheFileWritesOnlyAWholeCatalog(in: folder)
        freshnessIsADayAndNeverInTheFuture()
        theShelvesAreOrderedAndShareNothing()
        aPartialCatalogShowsOnlyItsOrder()
        everyListIsWholeAndOrdered()
        categoriesCountAndFilter()
        searchRanksTheTitleFirst()
        searchFindsEveryWordAnywhere()
        installStateFollowsTheRecordedCommit()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Decoding

    static func theCatalogEndpointDecodes() {
        guard let page = try? ExtensionStoreWire.page(fixture("search.json")) else {
            return expect(false, "the catalog page decodes")
        }
        expect(page.total == 3411, "the catalog reports its total")
        expect(page.entries.count == 6, "every macOS entry decodes, empty platforms included")
        let kinopio = page.entries.first { $0.name == "kinopio-inbox" }
        expect(kinopio?.title == "Kinopio Inbox", "the title")
        expect(kinopio?.summary == "Add cards to your Kinopio inbox", "the description")
        expect(kinopio?.author == "pirijan", "the author's name")
        expect(page.entries.first { $0.name == "driveway" }?.author == "Pankaj Popli", "a full name")
        expect(kinopio?.handle == "pirijan", "the owner's handle")
        expect(kinopio?.categories == ["Productivity", "Web"], "the categories, in order")
        expect(kinopio?.downloads == 202, "the downloads")
        expect(kinopio?.createdAt == Date(timeIntervalSince1970: 1_673_983_121), "created, in unix seconds")
        expect(kinopio?.updatedAt == Date(timeIntervalSince1970: 1_790_759_981), "updated, in unix seconds")
        expect(kinopio?.commitSHA?.hasPrefix("30296ed") == true, "the commit")
        expect(kinopio?.commands.count == 2, "the commands")
        expect(kinopio?.commands.allSatisfy { !$0.title.isEmpty } == true, "each command has its title")
        expect(
            kinopio?.storeURL?.absoluteString == "https://www.raycast.com/pirijan/kinopio-inbox",
            "the store page is built from the handle and name")
        expect(page.entries.first { $0.name == "snapset" }?.isNew == true, "is_new")
        expect(page.entries.first { $0.name == "rg-adguard-links" }?.categories == [], "no categories")
        let driveway = page.entries.first { $0.name == "driveway" }
        expect(driveway?.darkIcon != nil && driveway?.lightIcon != nil, "both icons")
        expect(driveway?.iconURL(isDark: true) == driveway?.darkIcon, "dark artwork in dark mode")
        let squid = page.entries.first { $0.name == "happy-squid" }
        expect(squid?.handle == "happy-squid", "the owner's handle wins over the author's")
        expect(page.entries.allSatisfy { $0.iconURL(isDark: false) != nil }, "every entry has artwork")
    }

    static func thePopularEndpointDecodes() {
        guard let page = try? ExtensionStoreWire.page(fixture("popular.json")) else {
            return expect(false, "the popular page decodes")
        }
        expect(page.total == 3448, "popular reports the whole store")
        expect(
            page.entries.map(\.name) == ["kill-process", "color-picker", "google-chrome", "translate"],
            "popular keeps the store's order")
        expect(page.entries.first?.downloads == 787_940, "the most installed first")
        let picker = page.entries.first { $0.name == "color-picker" }
        expect(picker?.iconURL(isDark: true) == picker?.lightIcon, "light artwork stands in for dark")
    }

    static func theStoreListingDecodes() {
        guard let page = try? ExtensionStoreWire.page(fixture("store-listings.json")) else {
            return expect(false, "the store listing decodes")
        }
        expect(page.total == nil, "the listing reports no total")
        expect(
            page.entries.map(\.name) == ["translate", "spotify-player", "visual-studio-code", "brew"],
            "the listing keeps Raycast's order")
        expect(
            page.entries.first { $0.name == "brew" }?.categories == ["Developer Tools", "System"],
            "the listing's entries are whole")
    }

    static func aHostilePageSkipsOnlyItsBadEntries() {
        guard let page = try? ExtensionStoreWire.page(fixture("hostile.json")) else {
            return expect(false, "a page with bad entries still decodes")
        }
        expect(page.total == 7, "a total spelled as a string")
        expect(
            page.entries.map(\.name) == ["odd-types", "minimal"],
            "Windows-only, deprecated, kill-listed, id-less and non-object entries are dropped")
        let odd = page.entries.first
        expect(odd?.title == "odd-types", "a title of the wrong type falls back to the name")
        expect(odd?.summary == "", "a null description is empty")
        expect(odd?.handle == "odd-owner", "an author of the wrong type leaves the owner")
        expect(odd?.author == "odd-owner", "and the author falls back to the handle")
        expect(odd?.lightIcon == nil, "an insecure icon is refused")
        expect(odd?.darkIcon?.absoluteString == "https://files.raycast.com/dark", "an https icon is kept")
        expect(odd?.commands.map(\.title) == ["One", "two", "Three"], "bad commands are skipped")
        expect(odd?.commands.last?.summary == "", "a description of the wrong type is empty")
        expect(odd?.categories == ["Productivity", "Developer Tools"], "bad categories are skipped")
        expect(odd?.downloads == 1234, "a count spelled as a string")
        expect(odd?.createdAt == Date(timeIntervalSince1970: 1_791_000_000), "a date spelled as a string")
        expect(odd?.updatedAt == Date(timeIntervalSince1970: 1_791_500_000.75), "a fractional date")
        expect(odd?.isNew == false, "is_new of the wrong type is false")
        expect(odd?.commitSHA == nil, "a commit of the wrong type is none")
        let minimal = page.entries.last
        expect(minimal?.handle == "minimal-owner", "the handle read from the store URL")
        expect(minimal?.title == "minimal" && minimal?.downloads == 0, "every other field defaults")
    }

    static func somethingThatIsNotAPageThrows() {
        expect((try? ExtensionStoreWire.page(Data("<html></html>".utf8))) == nil, "HTML is not a page")
        expect((try? ExtensionStoreWire.page(Data("{}".utf8))) == nil, "an object without data is not")
        expect((try? ExtensionStoreWire.page(Data("[]".utf8))) == nil, "a bare array is not")
        expect(
            (try? ExtensionStoreWire.page(Data(#"{"data":[]}"#.utf8)))?.entries.isEmpty == true,
            "an empty page is a page")
    }

    static func endpointsAreBuiltAsProbed() {
        let catalog = ExtensionStoreEndpoint.catalog(page: 3)?.absoluteString ?? ""
        expect(catalog.hasPrefix("https://www.raycast.com/frontend_api/extensions/search?"), "the catalog")
        expect(catalog.contains("q=&") && catalog.contains("page=3"), "with no query, by page")
        expect(catalog.contains("platform=macOS") && catalog.contains("per_page=200"), "macOS, 200 a page")
        expect(
            ExtensionStoreEndpoint.popular(page: 2)?.absoluteString
                == "https://www.raycast.com/frontend_api/extensions?page=2", "popular")
        expect(
            ExtensionStoreEndpoint.featured()?.absoluteString
                == "https://backend.raycast.com/api/v1/store_listings?per_page=100&page=1", "the listing")
        expect(
            ExtensionStoreEndpoint.search("git hub")?.absoluteString.contains("q=git%20hub") == true,
            "a query is escaped")
        expect(ExtensionStoreEndpoint.remainingCatalogPages(total: 3411) == 17, "3411 is 17 more pages")
        expect(ExtensionStoreEndpoint.remainingCatalogPages(total: 200) == 0, "one page is all")
        expect(ExtensionStoreEndpoint.remainingCatalogPages(total: nil) == 0, "no total, no more")
        expect(ExtensionStoreEndpoint.remainingCatalogPages(total: 1_000_000) == 39, "a ceiling on pages")
    }

    // MARK: - Catalog and cache

    static func entry(
        _ name: String, downloads: Int = 0, created: TimeInterval? = nil, updated: TimeInterval? = nil,
        categories: [String] = [], isNew: Bool = false, commit: String? = nil, title: String? = nil,
        summary: String = "", author: String = "someone", commands: [String] = []
    ) -> ExtensionStoreEntry {
        ExtensionStoreEntry(
            id: "id-" + name, name: name, title: title ?? name.capitalized, summary: summary,
            author: author, handle: author, lightIcon: URL(string: "https://files.raycast.com/" + name),
            darkIcon: nil, commands: commands.map { ExtensionStoreEntry.Command(title: $0, summary: "") },
            categories: categories, downloads: downloads,
            createdAt: created.map { now.addingTimeInterval(-$0) },
            updatedAt: updated.map { now.addingTimeInterval(-$0) }, isNew: isNew, commitSHA: commit)
    }

    static let day: TimeInterval = 24 * 3600

    static func theCatalogKeepsTheFirstCopyOfAnID() {
        let catalog = ExtensionStoreCatalog(
            entries: [entry("a", downloads: 5), entry("b"), entry("a", downloads: 9)],
            featured: [entry("c"), entry("a", downloads: 1), entry("c")], fetchedAt: now, isComplete: true)
        expect(catalog.entries.map(\.name) == ["a", "b", "c"], "one copy of each, featured-only ones too")
        expect(catalog.entry(id: "id-a")?.downloads == 5, "the catalog's own copy wins")
        expect(catalog.featured == ["id-c", "id-a"], "the featured order, once each")
    }

    static func sampleCatalog() -> ExtensionStoreCatalog {
        ExtensionStoreCatalog(
            entries: [
                entry(
                    "ünïcode", downloads: 3, created: 400 * day, updated: 2 * day, categories: ["Web"],
                    commit: "abc", title: "Ünïcode Tools", summary: "Line one\nline two",
                    commands: ["Search", "Copy"]),
                entry("bare", downloads: 1)
            ],
            featured: [entry("bare")], fetchedAt: now, isComplete: true)
    }

    static func theCacheRoundTrips() {
        let catalog = sampleCatalog()
        guard let data = try? ExtensionStoreCacheFormat.encode(catalog),
            let read = ExtensionStoreCacheFormat.decode(data)
        else { return expect(false, "the cache encodes and decodes") }
        expect(read == catalog, "a cached catalog reads back as written")
        expect(read.isComplete, "a cached catalog is whole")
        expect(data.count < 2_000, "the cache stays trimmed")
        let text = String(bytes: data, encoding: .utf8) ?? ""
        expect(!text.contains("download_url") && !text.contains("verify="), "no download URL is cached")
    }

    static func theCacheToleratesOtherBuilds() {
        let later = #"""
            {"version": 9, "fetchedAt": 1792800000, "featured": ["id-x", "id-gone"],
             "somethingNew": [1, 2], "entries": [
              {"id": "id-x", "name": "x", "future": {"a": 1}},
              {"id": "id-y", "name": "y", "downloads": "many", "title": "Y"},
              {"name": "no-id"},
              {"id": "id-z", "name": "z", "commands": [["Run"], ["Go", "Goes"], []], "created": 1790000000}
             ]}
            """#
        let read = ExtensionStoreCacheFormat.decode(Data(later.utf8))
        expect(read?.entries.map(\.name) == ["x", "z"], "a later build's entries read; broken ones skip")
        expect(read?.entries.first?.title == "x", "a missing title is the name")
        expect(read?.featured == ["id-x"], "a featured id no entry has is dropped")
        expect(read?.entries.last?.commands.map(\.title) == ["Run", "Go"], "commands tolerate short pairs")
        expect(read?.entries.last?.commands.last?.summary == "Goes", "and keep their summaries")
        expect(read?.fetchedAt == Date(timeIntervalSince1970: 1_792_800_000), "the fetch date")
        expect(ExtensionStoreCacheFormat.decode(Data("not json".utf8)) == nil, "garbage reads as none")
        expect(ExtensionStoreCacheFormat.decode(Data(#"{"entries": []}"#.utf8)) == nil, "no date, none")
        expect(
            ExtensionStoreCacheFormat.decode(Data(#"{"fetchedAt": 1, "entries": []}"#.utf8)) == nil,
            "an empty catalog reads as none")
    }

    static func theCacheFileWritesOnlyAWholeCatalog(in folder: URL) throws {
        let cache = ExtensionStoreCache(fileURL: folder.appending(path: "nested/extension-store.json"))
        expect(cache.read() == nil, "no file reads as none")
        var partial = sampleCatalog()
        partial.isComplete = false
        cache.write(partial)
        expect(
            !FileManager.default.fileExists(atPath: cache.fileURL.path), "a partial catalog is never cached")
        cache.write(sampleCatalog())
        expect(cache.read() == sampleCatalog(), "a whole one is, in a folder made for it")
        try Data("corrupt".utf8).write(to: cache.fileURL)
        expect(cache.read() == nil, "a corrupt file reads as none")
        expect(
            ExtensionStoreCache.standard().fileURL.lastPathComponent == "extension-store.json",
            "the standard file")
        expect(ExtensionStoreCache.standard().fileURL.path.contains("/Caches/"), "lives in Caches")
    }

    static func freshnessIsADayAndNeverInTheFuture() {
        var catalog = sampleCatalog()
        catalog.fetchedAt = now.addingTimeInterval(-(day - 60))
        expect(catalog.isFresh(now: now), "under a day is fresh")
        catalog.fetchedAt = now.addingTimeInterval(-day)
        expect(!catalog.isFresh(now: now), "a day is stale")
        catalog.fetchedAt = now.addingTimeInterval(3600)
        expect(!catalog.isFresh(now: now), "a cache stamped in the future is stale")
    }

    // MARK: - Shelves

    static func shelfCatalog() -> ExtensionStoreCatalog {
        var entries: [ExtensionStoreEntry] = []
        for index in 0..<10 {
            entries.append(
                entry(
                    "old\(index)", downloads: 1_000 - index, created: 500 * day,
                    updated: Double(100 + index) * day,
                    categories: index.isMultiple(of: 2) ? ["Web"] : ["Fun"]))
        }
        entries.append(entry("fresh", downloads: 5, created: 2 * day, updated: 1 * day, categories: ["Fun"]))
        entries.append(entry("flagged", downloads: 4, created: 300 * day, updated: 0.5 * day, isNew: true))
        entries.append(entry("undated", downloads: 3))
        let featured = ["old9", "old8", "fresh"].compactMap { name in entries.first { $0.name == name } }
        return ExtensionStoreCatalog(entries: entries, featured: featured, fetchedAt: now, isComplete: true)
    }

    static func names(_ rows: [ExtensionStoreRow], in section: ExtensionStoreSection) -> [String] {
        rows.filter { $0.section == section }.compactMap(\.entry?.name)
    }

    static func theShelvesAreOrderedAndShareNothing() {
        let rows = ExtensionStoreShelves.discover(shelfCatalog(), now: now)
        expect(names(rows, in: .shelf(.featured)) == ["old9", "old8", "fresh"], "Featured in Raycast's order")
        expect(!rows.contains { $0.item == .browse(.featured, count: 3) }, "a whole shelf has no Show All")
        expect(
            names(rows, in: .shelf(.popular)) == ["old0", "old1", "old2", "old3", "old4", "old5"],
            "Popular by downloads, six of them, skipping Featured")
        expect(rows.contains { $0.item == .browse(.popular, count: 13) }, "Popular's Show All counts all")
        expect(
            names(rows, in: .shelf(.recentlyUpdated)) == ["flagged", "old6", "old7"],
            "Recently Updated, newest first, skipping both shelves above")
        expect(names(rows, in: .shelf(.new)).isEmpty, "a shelf with nothing new left is dropped")
        expect(!rows.contains { $0.section == .shelf(.new) }, "and its header with it")
        let categories = rows.filter { $0.section == .categories }.map(\.item)
        expect(
            categories == [.browse(.category("Fun"), count: 6), .browse(.category("Web"), count: 5)],
            "categories, largest first, with their counts")
        expect(Set(rows.map(\.id)).count == rows.count, "every row has its own id")
        let sections = rows.map(\.section)
        let runs = zip(sections, sections.dropFirst()).filter { $0 != $1 }.count + 1
        expect(runs == Set(sections).count, "each section is one run, so it has one header")
    }

    static func aPartialCatalogShowsOnlyItsOrder() {
        var partial = shelfCatalog()
        partial.isComplete = false
        let rows = ExtensionStoreShelves.discover(partial, now: now)
        expect(Set(rows.map(\.section)) == [.shelf(.featured), .shelf(.popular)], "only Featured and Popular")
    }

    static func everyListIsWholeAndOrdered() {
        let catalog = shelfCatalog()
        let popular = ExtensionStoreShelves.listing(.popular, in: catalog, now: now)
        expect(
            popular.count == 13 && popular.first?.name == "old0" && popular.last?.name == "undated",
            "Popular is every entry by downloads")
        let updated = ExtensionStoreShelves.listing(.recentlyUpdated, in: catalog, now: now)
        expect(updated.prefix(3).map(\.name) == ["flagged", "fresh", "old0"], "newest update first")
        expect(!updated.contains { $0.name == "undated" }, "an entry never dated isn't recently updated")
        let new = ExtensionStoreShelves.listing(.new, in: catalog, now: now)
        expect(new.map(\.name) == ["fresh", "flagged"], "published in two weeks, or flagged new")
        expect(
            ExtensionStoreShelves.listing(.featured, in: catalog, now: now).map(\.name)
                == ["old9", "old8", "fresh"], "Featured in full")
        expect(ExtensionStoreShelves.isNew(entry("x", created: 13 * day), now: now), "13 days is new")
        expect(!ExtensionStoreShelves.isNew(entry("x", created: 15 * day), now: now), "15 days is not")
    }

    static func categoriesCountAndFilter() {
        let catalog = ExtensionStoreCatalog(
            entries: [
                entry("a", downloads: 1, categories: ["Web", "Web", "Fun"]),
                entry("b", downloads: 9, categories: ["Web"]),
                entry("c", downloads: 5, categories: ["Data"]),
                entry("d", downloads: 2, categories: ["Fun"])
            ],
            fetchedAt: now, isComplete: true)
        let counted = ExtensionStoreShelves.categories(in: catalog)
        expect(counted.map(\.name) == ["Fun", "Web", "Data"], "ties by name, a duplicate counted once")
        expect(counted.map(\.count) == [2, 2, 1], "the counts")
        expect(
            ExtensionStoreShelves.listing(.category("Web"), in: catalog, now: now).map(\.name) == ["b", "a"],
            "a category by downloads")
        expect(ExtensionStoreShelves.listing(.category("None"), in: catalog, now: now).isEmpty, "unknown")
        expect(
            ExtensionStoreBrowse.category("Web").title == "Web", "a category is titled as the store spells it"
        )
    }

    // MARK: - Search

    static func search(_ entries: [ExtensionStoreEntry], _ query: String) -> [String] {
        ExtensionStoreQuery.search(entries, keys: entries.map(ExtensionStoreSearchKey.init), query: query)
            .map(\.name)
    }

    static func searchRanksTheTitleFirst() {
        let entries = [
            entry("mentions", downloads: 900, title: "Mentions", summary: "Works with git repos"),
            entry("github", downloads: 10, title: "GitHub"),
            entry("git-mojis", downloads: 50, title: "Gitmoji"),
            entry("lazy", downloads: 70, title: "Lazy Git"),
            entry("legit", downloads: 80, title: "Legit"),
            entry("kill-process", downloads: 1, title: "Process Killer")
        ]
        expect(
            search(entries, "git") == ["git-mojis", "github", "lazy", "legit", "mentions"],
            "prefix by downloads, then word start, then inside, then the description")
        expect(search(entries, "GIT").first == "git-mojis", "case folds")
        expect(search(entries, "kill process") == ["kill-process"], "the slug, with dashes as spaces")
        expect(search(entries, "nothing like it").isEmpty, "a word found nowhere excludes")
        expect(search(entries, "   ") == entries.map(\.name), "a blank query keeps the list")
        expect(search(entries, "gtb").isEmpty, "subsequences are left out")
        let unicode = [entry("cafe", title: "Café Finder")]
        expect(search(unicode, "cafe") == ["cafe"], "diacritics fold")
    }

    static func searchFindsEveryWordAnywhere() {
        let entries = [
            entry(
                "notes", downloads: 3, categories: ["Productivity"], title: "Notes", author: "Jane Doe",
                commands: ["Search Notes", "Create Note"]),
            entry("other", downloads: 5, title: "Other", summary: "Productivity for notes")
        ]
        expect(search(entries, "jane").first == "notes", "the author")
        expect(search(entries, "create note") == ["notes"], "words across a command title")
        expect(
            search(entries, "productivity notes") == ["other", "notes"], "every word anywhere, by downloads")
        expect(search(entries, "notes").first == "notes", "the title before the description")
    }

    // MARK: - Install state

    static func installStateFollowsTheRecordedCommit() {
        let current = entry("ext", commit: "new")
        var installed = ExtensionStoreInstallState.Installed()
        expect(ExtensionStoreInstallState.of(current, in: installed) == .available, "not installed")
        installed.names = ["ext"]
        expect(ExtensionStoreInstallState.of(current, in: installed) == .installed, "a folder install")
        installed.storeCommits = ["ext": String?.none]
        expect(ExtensionStoreInstallState.of(current, in: installed) == .installed, "an unknown commit")
        installed.storeCommits = ["ext": "new"]
        expect(ExtensionStoreInstallState.of(current, in: installed) == .installed, "the same commit")
        installed.storeCommits = ["ext": "old"]
        expect(ExtensionStoreInstallState.of(current, in: installed) == .updateAvailable, "an older commit")
        expect(
            ExtensionStoreInstallState.of(entry("ext"), in: installed) == .installed,
            "an entry without a commit has nothing newer")
        installed.storeCommits = [:]
        installed.pendingUpdates = ["ext"]
        expect(
            ExtensionStoreInstallState.of(current, in: installed) == .updateAvailable, "Settings found one")
    }
}
