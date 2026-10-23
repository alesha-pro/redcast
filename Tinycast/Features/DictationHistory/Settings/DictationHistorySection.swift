import SwiftUI

/// The Dictation pane's History: how long transcripts stay, the command's shortcut, and Clear.
struct DictationHistorySection: View {
    @Environment(AppCore.self) private var core

    var body: some View {
        let coordinator = core.dictationHistoryCoordinator
        Section {
            Picker(selection: retentionBinding) {
                ForEach(DictationHistoryRetention.allCases) { retention in
                    Text(retention.title).tag(retention)
                }
            } label: {
                SettingsRowTitle(.dictationHistory, "Keep history")
                Text("Shortening it removes older transcripts at once.")
            }
            ForEach(CommandCatalog.entries(ownedBy: .dictation)) { entry in
                FeatureCommandRow(entry: entry)
            }
            .settingsEnabled(coordinator.settings.retention.keepsHistory)
            LabeledContent {
                Button("Clear…", role: .destructive) { Task { await coordinator.clearHistory() } }
            } label: {
                SettingsRowTitle(.dictationHistory, "Clear history")
                Text("Removes every transcript in the history.")
            }
        } header: {
            SettingsSectionHeader(.dictationHistory)
        } footer: {
            Text(
                """
                Finished dictations, Ask by Voice questions and voice edits are kept on this Mac as \
                text, never as audio, and are left out of exported backups.
                """)
        }
    }

    private var retentionBinding: Binding<DictationHistoryRetention> {
        Binding(
            get: { core.dictationHistoryCoordinator.settings.retention },
            set: { core.dictationHistoryCoordinator.setRetention($0) })
    }
}
