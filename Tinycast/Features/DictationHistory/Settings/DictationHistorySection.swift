import SwiftUI

/// The Dictation pane's History: how long transcripts stay, what joins them, the shortcut, Clear.
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
            Toggle(isOn: voiceRepliesBinding) {
                SettingsRowTitle(.dictationHistory, "Include Ask by Voice and voice edits")
                Text(
                    """
                    Also keeps each question with its answer, and each edit's instruction with the \
                    edited text.
                    """)
            }
            .settingsEnabled(coordinator.settings.retention.keepsHistory)
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
                The history is kept on this Mac as text, never as audio, and is left out of exported \
                backups.
                """)
        }
    }

    private var voiceRepliesBinding: Binding<Bool> {
        Binding(
            get: { core.dictationHistoryCoordinator.settings.keepsVoiceReplies },
            set: { core.dictationHistoryCoordinator.setKeepsVoiceReplies($0) })
    }

    private var retentionBinding: Binding<DictationHistoryRetention> {
        Binding(
            get: { core.dictationHistoryCoordinator.settings.retention },
            set: { core.dictationHistoryCoordinator.setRetention($0) })
    }
}
