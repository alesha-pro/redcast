import SwiftUI

/// Fork: Settings → AI → AI Chat Window: auto-archive and the finish banner, both off at first.
struct ChatWorkspaceSettingsSection: View {
    @Environment(AppCore.self) private var core

    var body: some View {
        let settings = core.chatWorkspace.settings
        Section {
            Picker(
                selection: Binding(
                    get: { settings.autoArchive },
                    set: { value in
                        settings.autoArchive = value
                        core.chatWorkspace.tidy()
                    })
            ) {
                ForEach(ChatAutoArchive.allCases) { Text($0.title).tag($0) }
            } label: {
                SettingsRowTitle(.aiChatWindow, "Archive inactive chats")
                Text("Unpinned chats left alone this long move to Archived as history loads.")
            }
            Toggle(isOn: notifyBinding(settings)) {
                SettingsRowTitle(.aiChatWindow, "Notify when a reply finishes")
                Text("A banner when a chat finishes while AI Chat's window is in the background.")
            }
        } header: {
            SettingsSectionHeader(.aiChatWindow)
        } footer: {
            Text("Deleted chats wait in Recently Deleted for 60 days before they go for good.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Turning it on is what asks macOS; a refusal turns it back off and says where to change it.
    private func notifyBinding(_ settings: ChatWorkspaceSettings) -> Binding<Bool> {
        Binding(
            get: { settings.notifiesInBackground },
            set: { on in
                settings.notifiesInBackground = on
                guard on else { return }
                Task {
                    guard await !ChatFinishNotifier.authorize() else { return }
                    settings.notifiesInBackground = false
                    core.showMessage(
                        String(localized: "Notifications are off for this app. Turn them on in System Settings first."),
                        tone: .neutral)
                }
            })
    }
}
