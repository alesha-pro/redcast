import Foundation
import Observation

/// The catalog while the store screen is open, and nothing from `close()` on.
@MainActor
@Observable
final class ExtensionStoreIndex {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var catalog: ExtensionStoreCatalog?
    private(set) var phase: Phase = .idle
    private(set) var isRefreshing = false
    /// Why the last background refresh failed, shown while the older catalog stays listed.
    private(set) var refreshFailure: String?
    /// The list being browsed, or nil for the shelves.
    var browse: ExtensionStoreBrowse? {
        didSet { memo = nil }
    }
    /// What the search endpoint answered while the catalog was still loading.
    private(set) var remote: (query: String, entries: [ExtensionStoreEntry])?
    private(set) var remoteFailure: String?
    /// Per manifest name; kept across a close, since an install outlives the screen.
    private(set) var installing: [String: String] = [:]
    private(set) var failures: [String: String] = [:]

    @ObservationIgnored private var keys: [ExtensionStoreSearchKey] = []
    @ObservationIgnored private var memo: (query: String, revision: Int, rows: [ExtensionStoreRow])?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var leaders: (revision: Int, titles: [ExtensionStoreBrowse: [String]]) =
        (0, [:])

    /// Local search needs the whole catalog; until then a query asks the store.
    var searchesLocally: Bool { catalog?.isComplete == true }

    /// Memoised on (query, browse, revision): the palette rebuilds the screen many times a render.
    func rows(for query: String) -> [ExtensionStoreRow] {
        _ = catalog
        _ = remote
        _ = browse
        if let memo, memo.query == query, memo.revision == revision { return memo.rows }
        let rows = build(query: query.trimmingCharacters(in: .whitespacesAndNewlines))
        memo = (query, revision, rows)
        return rows
    }

    private func build(query: String) -> [ExtensionStoreRow] {
        let now = Date()
        guard let catalog else { return remoteRows(query) }
        if query.isEmpty {
            guard let browse else { return ExtensionStoreShelves.discover(catalog, now: now) }
            return ExtensionStoreShelves.listing(browse, in: catalog, now: now).map {
                ExtensionStoreRow(section: .shelf(browse), item: .entry($0))
            }
        }
        guard searchesLocally else { return remoteRows(query) }
        let scope: [ExtensionStoreEntry]
        let scopeKeys: [ExtensionStoreSearchKey]
        if let browse {
            let listed = Set(ExtensionStoreShelves.listing(browse, in: catalog, now: now).map(\.id))
            let kept = zip(catalog.entries, keys).filter { listed.contains($0.0.id) }
            (scope, scopeKeys) = (kept.map(\.0), kept.map(\.1))
        } else {
            (scope, scopeKeys) = (catalog.entries, keys)
        }
        return ExtensionStoreQuery.search(scope, keys: scopeKeys, query: query).map {
            ExtensionStoreRow(section: .results, item: .entry($0))
        }
    }

    /// The first few titles a list row leads with, sorted once per catalog rather than per render.
    func leadingTitles(of browse: ExtensionStoreBrowse) -> [String] {
        guard let catalog else { return [] }
        if leaders.revision != revision { leaders = (revision, [:]) }
        if let titles = leaders.titles[browse] { return titles }
        let titles = ExtensionStoreShelves.listing(browse, in: catalog, now: Date()).prefix(8).map(\.title)
        leaders.titles[browse] = titles
        return titles
    }

    private func remoteRows(_ query: String) -> [ExtensionStoreRow] {
        guard !query.isEmpty, let remote, remote.query == query else { return [] }
        return remote.entries.map { ExtensionStoreRow(section: .results, item: .entry($0)) }
    }

    // MARK: - Loading

    func beginLoading() {
        guard catalog == nil else { return }
        phase = .loading
    }

    func beginRefresh() {
        isRefreshing = true
        refreshFailure = nil
        if catalog == nil { phase = .loading }
    }

    /// Folded off-main first: three thousand entries are work enough to keep off the main actor.
    func show(_ catalog: ExtensionStoreCatalog) async {
        let keys = await Self.keys(for: catalog.entries)
        guard phase != .idle else { return }
        self.catalog = catalog
        self.keys = keys
        if catalog.isComplete { remote = nil }
        if case .category(let name) = browse,
            !catalog.entries.contains(where: { $0.categories.contains(name) })
        {
            browse = nil
        }
        phase = .ready
        changed()
    }

    func finishRefresh(failure: String?) {
        isRefreshing = false
        guard let failure else { return }
        if catalog == nil {
            phase = .failed(failure)
        } else {
            refreshFailure = failure
        }
    }

    func showRemote(_ entries: [ExtensionStoreEntry], for query: String) {
        remote = (query, entries)
        remoteFailure = nil
        changed()
    }

    func failRemote(_ message: String?) {
        remoteFailure = message
    }

    // MARK: - Installs

    func noteProgress(_ message: String?, for name: String) {
        installing[name] = message
        if message != nil { failures[name] = nil }
    }

    func noteFailure(_ message: String?, for name: String) {
        failures[name] = message
    }

    /// Everything the catalog held goes; an install still running keeps its progress.
    func close() {
        phase = .idle
        catalog = nil
        keys = []
        remote = nil
        remoteFailure = nil
        refreshFailure = nil
        isRefreshing = false
        browse = nil
        failures = [:]
        changed()
    }

    var isOpen: Bool { phase != .idle }

    private func changed() {
        revision += 1
        memo = nil
    }

    @concurrent
    private static func keys(for entries: [ExtensionStoreEntry]) async -> [ExtensionStoreSearchKey] {
        entries.map(ExtensionStoreSearchKey.init)
    }
}
