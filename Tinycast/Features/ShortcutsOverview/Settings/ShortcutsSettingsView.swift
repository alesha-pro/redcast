import SwiftUI

/// Settings › Shortcuts: every hotkey and alias in one list, edited in place with the panes' own fields.
struct ShortcutsSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @State private var filter = ShortcutFilter.all
    @State private var query = ""
    @State private var system: [SystemShortcut] = []
    /// A `Form` realizes every row it is handed, so the list grows a page at a time.
    @State private var shown = Self.page

    private static let page = 60

    var body: some View {
        let rows = ShortcutsInventory.rows(core: core)
        let issues = ShortcutAudit.issues(rows.map(\.entry), system: system)
        let visible = Set(filter.apply(rows.map(\.entry), query: query, issues: issues).map(\.id))
        let listed = rows.filter { visible.contains($0.id) }
        return Form {
            Section {
                SteadySegmentedPicker(
                    title: String(localized: "Show"),
                    options: ShortcutFilter.allCases.map { .init(value: $0, title: $0.title) },
                    selection: $filter)
                SettingsFilterField(prompt: "Search shortcuts and aliases…", query: $query)
                summary(rows, issues: issues)
            } header: {
                SettingsSectionHeader(.shortcutsOverview)
            }

            Section {
                if listed.isEmpty {
                    Text(query.isEmpty ? "Nothing here yet." : "No matches for “\(query)”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                ForEach(listed.prefix(shown)) { row in
                    ShortcutOverviewRow(row: row, issues: issues[row.id] ?? [])
                }
                if listed.count > shown {
                    Button("Show More (\(listed.count - shown))") { shown += Self.page }
                        .buttonStyle(.link)
                }
            } header: {
                SettingsSectionHeader(.shortcutsList)
            }

            Section {
                LabeledContent {
                    Text(settings.hyperKey.title).foregroundStyle(.secondary)
                } label: {
                    SettingsRowTitle(.shortcutsHyperKey, "Hyper Key")
                    Text("Chords shown as ✦ use it. Change it in General.")
                }
            } header: {
                SettingsSectionHeader(.shortcutsHyperKey)
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.shortcuts)
        .releasesFocusOnOutsideClick()
        .onAppear { system = ShortcutsInventory.systemShortcuts() }
        // Apple Shortcuts are discovered on demand, so the pane asks for them as it opens.
        .task { if settings.appleShortcutsEnabled { core.appleShortcutCoordinator.refresh() } }
        .onChange(of: filter) { shown = Self.page }
        .onChange(of: query) { shown = Self.page }
    }

    private func summary(_ rows: [ShortcutsInventory.Row], issues: [String: [ShortcutIssue]]) -> some View {
        let hotkeys = rows.filter(\.entry.hasHotkey).count
        let aliases = rows.filter(\.entry.hasAlias).count
        return LabeledContent {
            if !issues.isEmpty {
                Label("Conflicts: \(issues.count)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } label: {
            Text("With a hotkey: \(hotkeys) · With an alias: \(aliases)")
            Text("Conflicts are shortcuts used twice, shared aliases, and chords macOS keeps for itself.")
        }
    }
}

/// Icon, name, kind, alias and hotkey; the field and recorder are the ones every pane uses.
private struct ShortcutOverviewRow: View {
    let row: ShortcutsInventory.Row
    let issues: [ShortcutIssue]

    private var subtitle: String? {
        if !issues.isEmpty { return issues.map(\.text).joined(separator: " · ") }
        return row.entry.keyword.map { String(localized: "Keyword: \($0)") }
    }

    var body: some View {
        SettingsRow(
            title: row.entry.name, subtitle: subtitle, labelOpacity: row.entry.isDisabled ? 0.45 : 1
        ) {
            icon
        } trailing: {
            if !issues.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(subtitle ?? "")
                    .accessibilityLabel(subtitle ?? "")
            }
            Text(row.entry.kindLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 96, alignment: .trailing)
            if let key = row.entry.aliasKey {
                AliasField(key: key, name: row.entry.name)
            } else {
                Color.clear.frame(width: Theme.Size.shortcutRecorder, height: 24)
            }
            if let action = row.action {
                ShortcutRecorder(action: action)
            } else {
                Color.clear.frame(width: Theme.Size.shortcutRecorder, height: 24)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let app = row.app {
            AppIconView(app: app)
                .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
                .id(app.iconKey)
        } else {
            Image(systemName: row.symbol ?? "command")
                .foregroundStyle(.secondary)
                .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
        }
    }
}
