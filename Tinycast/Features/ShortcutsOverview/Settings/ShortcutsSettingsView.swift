import SwiftUI

/// Settings › Shortcuts: every hotkey and alias in one list, edited in place with the panes' own fields.
struct ShortcutsSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @State private var filter = ShortcutFilter.all
    @State private var query = ""
    @State private var system: [SystemShortcut] = []
    @State private var recorderFrame: CGRect?

    var body: some View {
        let rows = ShortcutsInventory.rows(core: core)
        let issues = ShortcutAudit.issues(rows.map(\.entry), system: system)
        let visible = Set(filter.apply(rows.map(\.entry), query: query, issues: issues).map(\.id))
        let listed = rows.filter { visible.contains($0.id) }
        return Form {
            SettingsPaneHeader(tab: .shortcuts, subtitle: "Every hotkey and alias, edited in one place.")

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
                } else {
                    ShortcutsColumnHeader()
                    // One row holding the table: a `Form` realizes every row it is handed.
                    ShortcutsOverviewTable(
                        rows: listed, issues: issues, aliases: core.aliases, hotKeys: core.hotKeys,
                        recorderFrame: $recorderFrame
                    )
                    .overlay(alignment: .topLeading) { recorderStandIn }
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
    }

    /// The open recorder's anchor can't leave its hosted row, so this republishes its bounds here.
    @ViewBuilder
    private var recorderStandIn: some View {
        if let recorderFrame {
            Color.clear
                .frame(width: recorderFrame.width, height: recorderFrame.height)
                .anchorPreference(key: ShortcutRecorderAnchorKey.self, value: .bounds) { $0 }
                .position(x: recorderFrame.midX, y: recorderFrame.midY)
                .allowsHitTesting(false)
        }
    }

    private func summary(_ rows: [ShortcutsInventory.Row], issues: [String: [ShortcutIssue]]) -> some View {
        let hotkeys = rows.filter(\.entry.hasHotkey).count
        let aliases = rows.filter(\.entry.hasAlias).count
        return LabeledContent {
            if !issues.isEmpty {
                Label("Conflicts: \(issues.count)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warningInk)
                    .monospacedDigit()
            }
        } label: {
            Text("With a hotkey: \(hotkeys) · With an alias: \(aliases)")
                .monospacedDigit()
            Text("Conflicts are shortcuts used twice, shared aliases, and chords macOS keeps for itself.")
        }
    }
}
