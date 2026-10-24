import SwiftUI

/// Dictation History: past transcripts, newest first, pasted again into the app in front.
struct DictationHistoryScreen: PaletteScreen {
    let coordinator: DictationHistoryCoordinator
    let index: DictationHistoryIndex
    let vm: PaletteState
    let metrics: InterfaceMetrics
    let openActions: () -> Void
    let rows: [DictationHistoryEntry]

    init(
        coordinator: DictationHistoryCoordinator, index: DictationHistoryIndex, vm: PaletteState,
        metrics: InterfaceMetrics, openActions: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.index = index
        self.vm = vm
        self.metrics = metrics
        self.openActions = openActions
        rows = index.rows(for: vm.query)
    }

    private func entry(at selection: Int) -> DictationHistoryEntry? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    var primaryActionTitle: String {
        if entry(at: vm.selection)?.isFailed == true { return String(localized: "Retry") }
        return vm.pasteTarget?.pasteTitle ?? String(localized: "Paste")
    }

    func hasPrimaryAction(at selection: Int) -> Bool { entry(at: selection) != nil }

    /// A failed entry's ↵ retries, which needs its recording and no retry already running.
    func isPrimaryActionEnabled(at selection: Int) -> Bool {
        guard let entry = entry(at: selection), entry.isFailed else { return true }
        return coordinator.canRetry(entry)
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        entry(at: selection).map {
            DictationHistoryActionsMenu.content(entry: $0, coordinator: coordinator, target: vm.pasteTarget)
        }
    }

    func activate(at selection: Int) {
        guard let entry = entry(at: selection) else { return }
        if entry.isFailed { coordinator.retry(entry) } else { coordinator.paste(entry) }
    }

    /// ⌘↵, as Clipboard History copies; ⌘C reaches the coordinator from the panel.
    func secondary(at selection: Int) -> Bool {
        guard let entry = entry(at: selection), !entry.isFailed else { return false }
        coordinator.copy(entry)
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        switch shortcut {
        case .commandDelete, .delete:
            if let entry = entry(at: selection) { coordinator.delete(entry) }
            return true
        case .deleteAll:
            Task { await coordinator.clearHistory() }
            return true
        case .copyFile:
            guard let entry = entry(at: selection), entry.transcript != nil else { return false }
            coordinator.copyTranscript(entry)
            return true
        default:
            return false
        }
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(
            DictationHistoryView(
                rows: rows, selection: selection, scroll: scroll, coordinator: coordinator, index: index,
                vm: vm, metrics: metrics, openActions: openActions, activate: activate(at:)))
    }
}

/// The screen's one view, so opening and leaving it is what loads and frees the history.
private struct DictationHistoryView: View {
    let rows: [DictationHistoryEntry]
    let selection: Int
    let scroll: ScrollIntent
    let coordinator: DictationHistoryCoordinator
    let index: DictationHistoryIndex
    let vm: PaletteState
    let metrics: InterfaceMetrics
    let openActions: () -> Void
    let activate: (Int) -> Void

    private var selected: DictationHistoryEntry? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    /// A container, so switching between the list and an empty state never reads as leaving.
    var body: some View {
        ZStack { content }
            .onAppear { coordinator.screenAppeared() }
            .onDisappear { coordinator.screenDisappeared() }
    }

    @ViewBuilder private var content: some View {
        if rows.isEmpty {
            if index.phase == .ready {
                let isEmpty = index.entries.isEmpty
                EmptyResults(
                    text: isEmpty
                        ? String(localized: "No dictations yet")
                        : String(localized: "No matching dictations"),
                    systemImage: isEmpty ? "waveform" : "magnifyingglass")
            }
        } else {
            HStack(spacing: 0) {
                DictationHistoryList(
                    rows: rows, selectedID: selected?.id, retries: index.retries, scroll: scroll,
                    onSelect: { entry in vm.selection = rows.firstIndex(of: entry) ?? 0 },
                    onActivate: { entry in
                        vm.selection = rows.firstIndex(of: entry) ?? 0
                        activate(vm.selection)
                    },
                    onActions: { entry in
                        vm.selection = rows.firstIndex(of: entry) ?? 0
                        openActions()
                    }
                )
                .frame(width: metrics.size.clipboardListWidth)
                Rectangle().fill(Theme.Colors.separator).frame(width: Theme.Size.hairline)
                DictationHistoryPreview(
                    entry: selected, recorded: selected.map { index.recordings.contains($0.id) } ?? false,
                    retrying: selected.map { index.retries.isRetrying($0.id) } ?? false)
            }
        }
    }
}

@MainActor
enum DictationHistoryActionsMenu {
    static func content(
        entry: DictationHistoryEntry, coordinator: DictationHistoryCoordinator, target: PasteTarget?
    ) -> PopoverMenuContent {
        if entry.isFailed { return failed(entry, coordinator: coordinator) }
        var items = [
            PopoverMenuItem(
                title: target?.pasteTitle ?? String(localized: "Paste"),
                icon: .paste(target, fallback: "doc.on.clipboard"), shortcut: "↵"
            ) {
                coordinator.paste(entry)
            },
            PopoverMenuItem(
                title: String(localized: "Copy to Clipboard"), systemImage: "doc.on.doc", shortcut: "⌘C"
            ) {
                coordinator.copy(entry)
            }
        ]
        if entry.transcript != nil {
            items.append(
                PopoverMenuItem(
                    title: entry.kind == .dictation
                        ? String(localized: "Copy Raw Transcript") : String(localized: "Copy Request"),
                    systemImage: "text.quote", shortcut: "⇧⌘C"
                ) {
                    coordinator.copyTranscript(entry)
                })
        }
        items += deletions(entry, coordinator: coordinator)
        return PopoverMenuContent(header: DictationHistoryList.title(of: entry, limit: 40), items: items)
    }

    /// Retry on what a dictation would use now, or on any route or model listed under Retry with.
    private static func failed(
        _ entry: DictationHistoryEntry, coordinator: DictationHistoryCoordinator
    ) -> PopoverMenuContent {
        let canRetry = coordinator.canRetry(entry)
        var items = [
            PopoverMenuItem(
                title: String(localized: "Retry"), systemImage: "arrow.clockwise", isEnabled: canRetry,
                shortcut: "↵"
            ) {
                coordinator.retry(entry)
            }
        ]
        if canRetry {
            let current = coordinator.currentRetryEngine
            for (position, choice) in coordinator.retryEngines.enumerated() {
                items.append(
                    PopoverMenuItem(
                        title: choice.title, icon: choice.engine == current ? .symbol("checkmark") : .blank,
                        sectionTitle: position == 0 ? String(localized: "Retry with") : nil,
                        startsSection: position == 0
                    ) {
                        coordinator.retry(entry, on: choice.engine)
                    })
            }
        }
        items += deletions(entry, coordinator: coordinator)
        return PopoverMenuContent(header: DictationHistoryList.title(of: entry, limit: 40), items: items)
    }

    private static func deletions(
        _ entry: DictationHistoryEntry, coordinator: DictationHistoryCoordinator
    ) -> [PopoverMenuItem] {
        [
            PopoverMenuItem(
                title: String(localized: "Delete Entry"), systemImage: "trash", startsSection: true,
                shortcut: "⌃X", isDestructive: true
            ) {
                coordinator.delete(entry)
            },
            PopoverMenuItem(
                title: String(localized: "Delete All Entries"), systemImage: "trash", shortcut: "⌃⇧X",
                isDestructive: true
            ) {
                Task { await coordinator.clearHistory() }
            }
        ]
    }
}
