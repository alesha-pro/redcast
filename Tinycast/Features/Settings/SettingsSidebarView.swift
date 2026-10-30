import SwiftUI

struct SettingsSidebarView: View {
    @Environment(SettingsNavigationState.self) private var navigation
    @State private var query = ""
    @State private var highlighted: SettingsSearchEntry.ID?
    @State private var searching = false

    var body: some View {
        // Computed once: the catalog ranks every row, and `found` reads it several times over.
        let results = query.isEmpty ? [] : SettingsSearchCatalog.results(for: query)
        return VStack(spacing: 0) {
            if query.isEmpty {
                browse
            } else {
                found(results)
            }
        }
        .searchable(text: $query, isPresented: $searching, placement: .sidebar, prompt: "Search")
        .onExitCommand { query = "" }
        .onChange(of: query) { _, _ in highlighted = nil }
        .background(focusShortcut)
    }

    // Fork: an AppKit table with a neutral sliding selection; see `SettingsSidebarTable`.
    private var browse: some View {
        SettingsSidebarTable(rows: browseRows, selection: AnyHashable(navigation.tab)) { id in
            if let tab = id.base as? SettingsTab { navigation.select(tab) }
        }
        // Reaches under the field: the system's soft edge needs the rows to scroll beneath it.
        .ignoresSafeArea()
    }

    private var browseRows: [SettingsSidebarTable.Row] {
        SettingsSection.allCases.enumerated().flatMap { index, section in
            let rows = section.tabs.map { tab in
                SettingsSidebarTable.Row(id: tab, title: tab.title) {
                    AnyView(SettingsSidebarRow(tab: tab, title: tab.title))
                }
            }
            guard index > 0 else { return rows }
            return [SettingsSidebarTable.Row(
                id: nil, title: section.title, height: Theme.Size.settingsSidebarGroupGap)] + rows
        }
    }

    @ViewBuilder private func found(_ results: [SettingsSearchEntry]) -> some View {
        if results.isEmpty {
            // Greedy: a finite max height here becomes a constraint that shrinks the whole window.
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SettingsSidebarTable(
                rows: results.map { entry in
                    SettingsSidebarTable.Row(
                        id: entry.id, title: entry.title,
                        height: Theme.Size.settingsSidebarResultRow
                    ) { AnyView(SettingsSearchResultRow(entry: entry)) }
                },
                selection: highlighted.map(AnyHashable.init),
                isResultsList: true,
                accessibilityLabel: String(localized: "Results")
            ) { id in
                guard let entry = results.first(where: { AnyHashable($0.id) == id }) else { return }
                highlighted = entry.id
                navigation.select(entry.tab, revealing: entry.target)
            }
            .ignoresSafeArea()
        }
    }

    /// ⌘F with no menu item to hang it on; zero-sized so it only ever contributes the shortcut.
    private var focusShortcut: some View {
        Button("Search Settings") { searching = true }
            .keyboardShortcut("f", modifiers: .command)
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

/// Knows nothing of selection: the table's pill moves and no row's `body` runs again.
private struct SettingsSidebarRow: View {
    let tab: SettingsTab
    let title: String
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        HStack(spacing: Theme.Size.settingsSidebarTileGap) {
            SettingsTabTile(tab: tab)
            Text(title)
                .lineLimit(1)
                .foregroundStyle(appearsActive ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(title)
        }
        .padding(.leading, Theme.Size.settingsSidebarRowInset + Theme.Size.settingsSidebarTileInset)
        .padding(.trailing, Theme.Size.settingsSidebarRowInset + Theme.Size.settingsSidebarTileInset)
        .frame(maxHeight: .infinity)
    }
}

private struct SettingsSearchResultRow: View {
    let entry: SettingsSearchEntry
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        HStack(spacing: Theme.Size.settingsSidebarTileGap) {
            SettingsTabTile(tab: entry.tab)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(entry.title).lineLimit(1)
                    .foregroundStyle(appearsActive ? .primary : .secondary)
                Text(entry.breadcrumb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(entry.title)
        }
        .padding(.leading, Theme.Size.settingsSidebarRowInset + Theme.Size.settingsSidebarTileInset)
        .padding(.trailing, Theme.Size.settingsSidebarRowInset + Theme.Size.settingsSidebarTileInset)
        .frame(maxHeight: .infinity)
    }
}
