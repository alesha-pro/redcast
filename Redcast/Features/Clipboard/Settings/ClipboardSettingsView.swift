import SwiftUI
import UniformTypeIdentifiers

struct ClipboardSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Toggle(isOn: $settings.clipboardEnabled) {
                    SettingsFeatureToggleLabel(
                        anchor: .clipboardClipboard, title: "Enable Clipboard History",
                        subtitle: "Keep copied items ready to reuse.")
                }
            }
            .settingsAnchor(.clipboardClipboard)

            FeatureCommandsSection(owner: .clipboard, anchor: .clipboardCommands)
                .settingsEnabled(settings.clipboardEnabled)

            Section {
                Picker(selection: $settings.clipboardRetention) {
                    ForEach(ClipboardRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                } label: {
                    SettingsRowTitle(.clipboardHistory, "Keep history for")
                }
                Toggle(isOn: $settings.clipboardTextSearchEnabled) {
                    SettingsRowTitle(.clipboardHistory, "Search text in images and PDFs")
                    Text("Recognized on this Mac while idle.")
                }
                Picker(selection: $settings.clipboardDefaultAction) {
                    ForEach(ClipboardDefaultAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                } label: {
                    SettingsRowTitle(.clipboardHistory, "Default action")
                    Text("↵ does this, and Paste takes its shortcut.")
                }
            } header: {
                SettingsSectionHeader(.clipboardHistory)
            }
            .settingsEnabled(settings.clipboardEnabled)

            DisabledApplicationsSection(
                bundleIDs: $settings.clipboardDisabledApps,
                anchor: .clipboardDisabledApplications,
                footer: String(localized: "Copies from these apps aren't recorded.")
            )
            .settingsEnabled(settings.clipboardEnabled)

            Section {
                LabeledContent {
                    Button("Clear…", role: .destructive) { Task { await clearHistory() } }
                } label: {
                    SettingsRowTitle(.clipboardDisabledApplications, "Clear history")
                    Text("Removes every item in the history.")
                }
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.clipboard)
    }

    private func clearHistory() async {
        guard
            await core.confirm(
                title: String(localized: "Clear clipboard history?"),
                message: String(localized: "This can't be undone."), symbol: "doc.on.clipboard",
                confirmTitle: String(localized: "Clear History"))
        else { return }
        core.clipboardCoordinator.clearHistory()
    }
}
