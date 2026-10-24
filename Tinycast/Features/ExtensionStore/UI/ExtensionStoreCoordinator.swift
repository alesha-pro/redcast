import AppKit

/// The Extension Store's action surface: its command, the screen's catalog, and each row's actions.
@MainActor
final class ExtensionStoreCoordinator {
    private let settings: AppSettings
    private let extensions: ExtensionManager
    private let extensionCoordinator: ExtensionCoordinator
    private let appIndex: AppIndex
    private let paletteCoordinator: PaletteCoordinator
    private let palette: PaletteState
    /// HUDs stay owned by the composition root.
    private unowned let core: AppCore
    private let fetcher: ExtensionStoreFetcher
    private let cache: ExtensionStoreCache

    private var builtIndex: ExtensionStoreIndex?
    /// The open screen's load and refresh; closing the screen cancels it.
    private var loading: Task<Void, Never>?
    /// Installs and updates outlive the screen: each is the reader's own request.
    private var installs: [String: Task<Void, Never>] = [:]

    init(
        settings: AppSettings, extensions: ExtensionManager, extensionCoordinator: ExtensionCoordinator,
        appIndex: AppIndex, paletteCoordinator: PaletteCoordinator, palette: PaletteState, core: AppCore,
        fetcher: ExtensionStoreFetcher = ExtensionStoreFetcher(), cache: ExtensionStoreCache = .standard()
    ) {
        self.settings = settings
        self.extensions = extensions
        self.extensionCoordinator = extensionCoordinator
        self.appIndex = appIndex
        self.paletteCoordinator = paletteCoordinator
        self.palette = palette
        self.core = core
        self.fetcher = fetcher
        self.cache = cache
    }

    /// Built on the first open, never at launch.
    var index: ExtensionStoreIndex {
        if let builtIndex { return builtIndex }
        let index = ExtensionStoreIndex()
        builtIndex = index
        return index
    }

    /// Listed while extensions are on: turning them on is the consent installing builds on.
    var isActive: Bool { settings.extensionsEnabled }

    /// Command visibility only; nothing is read or fetched here.
    func applyEnabled() {
        appIndex.setCommandsVisible([.extensionStore], isActive)
        guard !isActive else { return }
        closeScreen()
        if palette.mode == .extensionStore { palette.prepare(mode: .launcher) }
    }

    // MARK: - The screen

    func show() {
        guard isActive else {
            core.showMessage(
                String(localized: "Extensions are disabled — enable them in Settings"), tone: .danger)
            return
        }
        paletteCoordinator.togglePalette(mode: .extensionStore)
    }

    /// A stale cache shows at once and refreshes behind it; a fresh one is all an open costs.
    func screenAppeared() {
        guard isActive, !index.isOpen else { return }
        index.beginLoading()
        let cache = cache
        loading = Task { [weak self] in
            let cached = await Self.read(cache)
            guard !Task.isCancelled, let self, let index = builtIndex else { return }
            if let cached { await index.show(cached) }
            guard !Task.isCancelled, cached?.isFresh(now: Date()) != true else { return }
            fetch()
        }
    }

    func screenDisappeared() {
        closeScreen()
    }

    /// ⌘R and the ⌘K row: the whole catalog again, whatever the cache's age.
    func refresh() {
        guard let builtIndex, builtIndex.isOpen, !builtIndex.isRefreshing else { return }
        fetch()
    }

    private func closeScreen() {
        loading?.cancel()
        loading = nil
        builtIndex?.close()
    }

    /// Featured and the first popular pages first when nothing is listed yet, then the catalog.
    private func fetch() {
        guard let index = builtIndex else { return }
        loading?.cancel()
        index.beginRefresh()
        let fetcher = fetcher
        let cache = cache
        let showsShelvesFirst = index.catalog == nil
        loading = Task { [weak self] in
            async let featured = fetcher.featured()
            async let catalog = Self.catalog(from: fetcher)
            if showsShelvesFirst {
                let popular = await fetcher.popular()
                let shelf = await featured
                guard !Task.isCancelled, let index = self?.builtIndex else { return }
                if index.catalog == nil, !(popular.isEmpty && shelf.isEmpty) {
                    await index.show(
                        ExtensionStoreCatalog(
                            entries: popular, featured: shelf, fetchedAt: Date(), isComplete: false))
                }
            }
            let fetched = await catalog
            let shelf = await featured
            guard !Task.isCancelled, let index = self?.builtIndex else { return }
            switch fetched {
            case .success(let fetched) where !fetched.entries.isEmpty:
                let next = ExtensionStoreCatalog(
                    entries: fetched.entries, featured: shelf, fetchedAt: Date(),
                    isComplete: fetched.isComplete)
                // A partial fetch never replaces a whole catalog the cache already showed.
                if next.isComplete || index.catalog?.isComplete != true { await index.show(next) }
                if next.isComplete { await Self.write(next, to: cache) }
                index.finishRefresh(
                    failure: next.isComplete ? nil : String(localized: "Part of the store didn't load."))
            case .success:
                index.finishRefresh(failure: ExtensionStoreError.malformedResponse.localizedDescription)
            case .failure(let error):
                guard !Task.isCancelled else { return }
                index.finishRefresh(failure: error.localizedDescription)
            }
        }
    }

    private static func catalog(
        from fetcher: ExtensionStoreFetcher
    ) async -> Result<(entries: [ExtensionStoreEntry], isComplete: Bool), any Error> {
        do {
            return .success(try await fetcher.catalog())
        } catch {
            return .failure(error)
        }
    }

    @concurrent
    private static func read(_ cache: ExtensionStoreCache) async -> ExtensionStoreCatalog? {
        cache.read()
    }

    @concurrent
    private static func write(_ catalog: ExtensionStoreCatalog, to cache: ExtensionStoreCache) async {
        cache.write(catalog)
    }

    /// A query before the catalog is whole asks the search endpoint, debounced by the view's task.
    func searchRemotely(_ query: String) async {
        guard !query.isEmpty, let index = builtIndex, index.isOpen, !index.searchesLocally else { return }
        index.failRemote(nil)
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let found = try await fetcher.search(query)
            guard !Task.isCancelled else { return }
            index.showRemote(found, for: query)
        } catch {
            guard !Task.isCancelled else { return }
            index.failRemote(error.localizedDescription)
        }
    }

    // MARK: - Browsing

    func browse(_ browse: ExtensionStoreBrowse?) {
        guard let builtIndex else { return }
        builtIndex.browse = browse
        palette.query = ""
        palette.selection = 0
        palette.resetToken = UUID()
    }

    /// Escape on an empty query leaves the list being browsed before it leaves the screen.
    func leaveBrowse() -> Bool {
        guard palette.mode == .extensionStore, builtIndex?.browse != nil else { return false }
        browse(nil)
        return true
    }

    // MARK: - Installed state

    var installed: ExtensionStoreInstallState.Installed {
        ExtensionStoreInstallState.Installed(
            names: Set(extensions.installed.map(\.manifest.name)), storeCommits: extensions.storeCommits,
            pendingUpdates: Set(extensions.updates.keys))
    }

    func state(of entry: ExtensionStoreEntry) -> ExtensionStoreInstallState {
        ExtensionStoreInstallState.of(entry, in: installed)
    }

    func isInstalling(_ entry: ExtensionStoreEntry) -> Bool { installs[entry.name] != nil }

    // MARK: - Actions

    /// ↵: Install, Update when the store has a newer commit, Open once it is current.
    func activate(_ entry: ExtensionStoreEntry) {
        switch state(of: entry) {
        case .available, .updateAvailable: install(entry)
        case .installed: open(entry)
        }
    }

    /// The listing is looked up again first: the store signs each download URL, and they expire.
    func install(_ entry: ExtensionStoreEntry) {
        guard isActive, installs[entry.name] == nil else { return }
        let updating = state(of: entry) == .updateAvailable
        let name = entry.name
        index.noteProgress(ExtensionInstaller.Progress.downloading.message, for: name)
        installs[name] = Task { [weak self] in
            await self?.performInstall(entry, updating: updating)
        }
    }

    private func performInstall(_ entry: ExtensionStoreEntry, updating: Bool) async {
        let name = entry.name
        let index = index
        defer {
            installs[name] = nil
            index.noteProgress(nil, for: name)
        }
        do {
            guard let listing = try await ExtensionStoreClient().lookup(handle: entry.handle, name: name)
            else {
                throw ExtensionStoreError.rejected(
                    String(localized: "\(entry.title) is no longer available in the Raycast Store."))
            }
            try await extensions.install(
                listing,
                onProgress: { progress in
                    // A step reported after the install ended must not bring its progress back.
                    Task { @MainActor in
                        guard index.installing[name] != nil else { return }
                        index.noteProgress(progress.message, for: name)
                    }
                })
            core.showMessage(
                updating
                    ? String(localized: "\(entry.title) is up to date")
                    : String(localized: "\(entry.title) is installed"))
        } catch {
            index.noteFailure(error.localizedDescription, for: name)
            core.showMessage(
                String(localized: "Couldn't install \(entry.title): \(error.localizedDescription)"),
                tone: .danger)
        }
    }

    /// One command runs; more are listed in root search, or in Settings when they're kept out of it.
    func open(_ entry: ExtensionStoreEntry) {
        guard let owner = extensions.extensionNamed(entry.name) else { return }
        let commands = owner.manifest.commands
        if commands.count == 1, let command = commands.first {
            extensionCoordinator.runExtensionCommand(
                entryID: ExtensionCommandRef(extensionName: owner.manifest.name, commandName: command.name)
                    .entryID)
        } else if settings.extensionsShowInLauncher, !commands.isEmpty {
            paletteCoordinator.showPalette(mode: .launcher, seeding: owner.title)
        } else {
            extensionCoordinator.showExtensionSettings(for: owner)
        }
    }

    /// Tinycast's own dialog asks first, as Settings' Uninstall does.
    func uninstall(_ entry: ExtensionStoreEntry) {
        guard let owner = extensions.extensionNamed(entry.name) else { return }
        extensionCoordinator.confirmUninstall(owner)
    }

    func showInSettings(_ entry: ExtensionStoreEntry) {
        guard let owner = extensions.extensionNamed(entry.name) else { return }
        extensionCoordinator.showExtensionSettings(for: owner)
    }

    func openInBrowser(_ entry: ExtensionStoreEntry) {
        guard let url = entry.storeURL else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        NSWorkspace.shared.open(url)
    }

    func copyStoreLink(_ entry: ExtensionStoreEntry) {
        guard let url = entry.storeURL else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(url.absoluteString)
    }
}
