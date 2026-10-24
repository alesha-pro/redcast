import SwiftUI

/// The Extension Store: shelves and categories with nothing typed, the catalog searched by typing.
struct ExtensionStoreScreen: PaletteScreen {
    let coordinator: ExtensionStoreCoordinator
    let index: ExtensionStoreIndex
    let vm: PaletteState
    let metrics: InterfaceMetrics
    let openActions: () -> Void
    let rows: [ExtensionStoreRow]
    let installed: ExtensionStoreInstallState.Installed

    init(
        coordinator: ExtensionStoreCoordinator, index: ExtensionStoreIndex, vm: PaletteState,
        metrics: InterfaceMetrics, openActions: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.index = index
        self.vm = vm
        self.metrics = metrics
        self.openActions = openActions
        rows = index.rows(for: vm.query)
        installed = coordinator.installed
    }

    private func row(at selection: Int) -> ExtensionStoreRow? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    private func entry(at selection: Int) -> ExtensionStoreEntry? {
        row(at: selection)?.entry
    }

    private func state(of entry: ExtensionStoreEntry) -> ExtensionStoreInstallState {
        ExtensionStoreInstallState.of(entry, in: installed)
    }

    var primaryActionTitle: String {
        guard let row = row(at: vm.selection) else { return String(localized: "Install") }
        guard let entry = row.entry else { return String(localized: "Show") }
        return Self.primaryTitle(state(of: entry))
    }

    static func primaryTitle(_ state: ExtensionStoreInstallState) -> String {
        switch state {
        case .available: String(localized: "Install")
        case .updateAvailable: String(localized: "Update")
        case .installed: String(localized: "Open Extension")
        }
    }

    func hasPrimaryAction(at selection: Int) -> Bool { row(at: selection) != nil }

    /// An install already running owns its row until it ends.
    func isPrimaryActionEnabled(at selection: Int) -> Bool {
        guard let entry = entry(at: selection) else { return true }
        return index.installing[entry.name] == nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let row = row(at: selection) else { return nil }
        return ExtensionStoreActionsMenu.content(
            row: row, state: row.entry.map(state(of:)), coordinator: coordinator, index: index)
    }

    func activate(at selection: Int) {
        guard let row = row(at: selection) else { return }
        switch row.item {
        case .entry(let entry):
            guard index.installing[entry.name] == nil else { return }
            coordinator.activate(entry)
        case .browse(let browse, _):
            coordinator.browse(browse)
        }
    }

    /// ⌘↵ opens the store page, the one thing every row with an extension has.
    func secondary(at selection: Int) -> Bool {
        guard let entry = entry(at: selection) else { return false }
        coordinator.openInBrowser(entry)
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        if shortcut == .restart {
            coordinator.refresh()
            return true
        }
        guard let entry = entry(at: selection) else { return false }
        switch shortcut {
        case .copyFile:
            coordinator.copyStoreLink(entry)
        case .openInApp:
            coordinator.openInBrowser(entry)
        case .delete where state(of: entry) != .available:
            coordinator.uninstall(entry)
        default:
            return false
        }
        return true
    }

    /// The list being browsed, which ✕ or Escape leaves, and a spinner while the catalog loads.
    func headerAccessory(
        at selection: Int, focus: FocusState<String?>.Binding
    ) -> PaletteHeaderAccessory? {
        let browse = index.browse
        let refreshing = index.isRefreshing
        guard browse != nil || refreshing else { return nil }
        let spinner = refreshing ? metrics.size.menuIcon + metrics.spacing.md : 0
        let chip =
            browse.map {
                ($0.title as NSString).size(withAttributes: [.font: metrics.typography.chipNSFont]).width
                    + metrics.size.menuIcon + metrics.spacing.md * 3
            } ?? 0
        return PaletteHeaderAccessory(
            width: spinner + chip + metrics.spacing.md, fieldNames: [], firstIncompleteField: nil,
            placement: .besideSearchField,
            view: AnyView(
                ExtensionStoreHeaderAccessory(
                    browse: browse, refreshing: refreshing, onClear: { coordinator.browse(nil) })))
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(
            ExtensionStoreView(
                rows: rows, selection: selection, scroll: scroll, coordinator: coordinator, index: index,
                installed: installed, vm: vm, metrics: metrics, openActions: openActions,
                activate: activate(at:)))
    }
}

private struct ExtensionStoreHeaderAccessory: View {
    @Environment(\.metrics) private var metrics
    let browse: ExtensionStoreBrowse?
    let refreshing: Bool
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: metrics.spacing.md) {
            if refreshing {
                ProgressView()
                    .controlSize(.small)
                    .help("Loading the Raycast Store…")
            }
            if let browse {
                BarButton(chrome: .rounded, isSelected: true, action: onClear) {
                    HStack(spacing: metrics.spacing.sm) {
                        Text(verbatim: browse.title)
                            .font(metrics.typography.chip)
                            .lineLimit(1)
                        Image(systemName: "xmark")
                            .font(metrics.typography.keyCap)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                .fixedSize()
                .help("Show every list and category  ⎋")
            }
        }
        .padding(.leading, metrics.spacing.md)
    }
}

/// The screen's one view, so opening and leaving it is what loads and frees the catalog.
private struct ExtensionStoreView: View {
    let rows: [ExtensionStoreRow]
    let selection: Int
    let scroll: ScrollIntent
    let coordinator: ExtensionStoreCoordinator
    let index: ExtensionStoreIndex
    let installed: ExtensionStoreInstallState.Installed
    let vm: PaletteState
    let metrics: InterfaceMetrics
    let openActions: () -> Void
    let activate: (Int) -> Void

    private var selected: ExtensionStoreRow? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    /// Only a query the catalog can't answer yet goes to the search endpoint.
    private var remoteQuery: String {
        let query = vm.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return index.searchesLocally ? "" : query
    }

    /// A container, so switching between the list and an empty state never reads as leaving.
    var body: some View {
        ZStack { content }
            .onAppear { coordinator.screenAppeared() }
            .onDisappear { coordinator.screenDisappeared() }
            .task(id: remoteQuery) { await coordinator.searchRemotely(remoteQuery) }
    }

    @ViewBuilder private var content: some View {
        if rows.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                ExtensionStoreList(
                    rows: rows, selectedID: selected?.id, installed: installed,
                    installing: index.installing, scroll: scroll,
                    onSelect: { row in vm.selection = rows.firstIndex(of: row) ?? 0 },
                    onActivate: { row in
                        vm.selection = rows.firstIndex(of: row) ?? 0
                        activate(vm.selection)
                    },
                    onActions: { row in
                        vm.selection = rows.firstIndex(of: row) ?? 0
                        openActions()
                    }
                )
                .frame(width: metrics.size.clipboardListWidth)
                Rectangle().fill(Theme.Colors.separator).frame(width: Theme.Size.hairline)
                ExtensionStorePreview(
                    row: selected, leadingTitles: index.leadingTitles(of:), installed: installed,
                    installing: selected?.entry.flatMap { index.installing[$0.name] },
                    failure: selected?.entry.flatMap { index.failures[$0.name] },
                    refreshFailure: index.refreshFailure)
            }
        }
    }

    /// A query the catalog can't answer yet says how its search is going before anything else.
    @ViewBuilder private var emptyState: some View {
        let query = vm.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let asksTheStore = !query.isEmpty && !index.searchesLocally && index.phase != .idle
        if asksTheStore, let failure = index.remoteFailure {
            EmptyResults(
                text: String(localized: "Couldn't search the Raycast Store"), detail: failure,
                systemImage: "exclamationmark.triangle")
        } else if asksTheStore, index.remote?.query == query {
            EmptyResults(text: String(localized: "No matching extensions"))
        } else if asksTheStore {
            progress(Text("Searching…"))
        } else {
            switch index.phase {
            case .idle:
                Color.clear
            case .loading:
                progress(Text("Loading the Raycast Store…"))
            case .failed(let failure):
                VStack(spacing: metrics.spacing.md) {
                    EmptyResults(
                        text: String(localized: "Couldn't reach the Raycast Store"), detail: failure,
                        systemImage: "wifi.exclamationmark"
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    Text("Press ⌘R to try again.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                EmptyResults(text: String(localized: "No matching extensions"))
            }
        }
    }

    private func progress(_ label: Text) -> some View {
        VStack(spacing: metrics.spacing.md) {
            ProgressView()
            label.foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
enum ExtensionStoreActionsMenu {
    static func content(
        row: ExtensionStoreRow, state: ExtensionStoreInstallState?, coordinator: ExtensionStoreCoordinator,
        index: ExtensionStoreIndex
    ) -> PopoverMenuContent {
        guard let entry = row.entry, let state else {
            return browseMenu(row: row, coordinator: coordinator, index: index)
        }
        let busy = index.installing[entry.name] != nil
        var items: [PopoverMenuItem] = []
        switch state {
        case .available:
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Install Extension"), systemImage: "arrow.down.circle",
                    isLoading: busy, shortcut: "↵"
                ) { coordinator.install(entry) })
        case .updateAvailable:
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Update Extension"), systemImage: "arrow.triangle.2.circlepath",
                    isLoading: busy, shortcut: "↵"
                ) { coordinator.install(entry) })
            items.append(open(entry, coordinator: coordinator, shortcut: nil))
        case .installed:
            items.append(open(entry, coordinator: coordinator, shortcut: "↵"))
        }
        items += [
            PopoverMenuItem(
                title: String(localized: "Open in Browser"), systemImage: "safari", startsSection: true,
                shortcut: "⌘↵"
            ) { coordinator.openInBrowser(entry) },
            PopoverMenuItem(
                title: String(localized: "Copy Store Link"), systemImage: "link", shortcut: "⇧⌘C"
            ) { coordinator.copyStoreLink(entry) }
        ]
        if state != .available {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Show in Settings"), systemImage: "gearshape"
                ) { coordinator.showInSettings(entry) })
        }
        for (position, category) in entry.categories.enumerated() {
            items.append(
                PopoverMenuItem(
                    title: category, systemImage: "square.grid.2x2",
                    sectionTitle: position == 0 ? String(localized: "Browse Category") : nil,
                    startsSection: position == 0
                ) { coordinator.browse(.category(category)) })
        }
        items += general(coordinator: coordinator, index: index)
        if state != .available {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Uninstall…"), systemImage: "trash", isEnabled: !busy,
                    startsSection: true, shortcut: "⌃X", isDestructive: true
                ) { coordinator.uninstall(entry) })
        }
        return PopoverMenuContent(header: entry.title, items: items)
    }

    private static func open(
        _ entry: ExtensionStoreEntry, coordinator: ExtensionStoreCoordinator, shortcut: String?
    ) -> PopoverMenuItem {
        PopoverMenuItem(
            title: String(localized: "Open Extension"), systemImage: "arrow.up.forward.app",
            shortcut: shortcut
        ) { coordinator.open(entry) }
    }

    private static func browseMenu(
        row: ExtensionStoreRow, coordinator: ExtensionStoreCoordinator, index: ExtensionStoreIndex
    ) -> PopoverMenuContent {
        guard case .browse(let browse, _) = row.item else {
            return PopoverMenuContent(header: nil, items: general(coordinator: coordinator, index: index))
        }
        let show = PopoverMenuItem(
            title: String(localized: "Show \(browse.title)"), systemImage: "list.bullet", shortcut: "↵"
        ) { coordinator.browse(browse) }
        return PopoverMenuContent(
            header: browse.title, items: [show] + general(coordinator: coordinator, index: index))
    }

    /// The screen's own rows: leaving the list being browsed, and fetching the catalog again.
    private static func general(
        coordinator: ExtensionStoreCoordinator, index: ExtensionStoreIndex
    ) -> [PopoverMenuItem] {
        var items: [PopoverMenuItem] = []
        if index.browse != nil {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Show All Lists"), systemImage: "square.stack",
                    startsSection: true, shortcut: "⎋"
                ) { coordinator.browse(nil) })
        }
        items.append(
            PopoverMenuItem(
                title: String(localized: "Refresh Store"), systemImage: "arrow.clockwise",
                isLoading: index.isRefreshing, startsSection: index.browse == nil, shortcut: "⌘R"
            ) { coordinator.refresh() })
        return items
    }
}
