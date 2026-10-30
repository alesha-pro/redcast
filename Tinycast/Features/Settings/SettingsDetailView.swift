import SwiftUI

struct SettingsDetailView: View {
    @Environment(SettingsNavigationState.self) private var navigation
    // Fork: the pane lags the selection, so a slow build never delays the sidebar's response.
    @State private var presented: SettingsTab?
    @State private var lastSelection = ContinuousClock.Instant.now - .seconds(1)

    var body: some View {
        // Not a `TabView`: `NSTabView` re-hosts on selection and breaks the recorder.
        Group {
            switch presented ?? navigation.tab {
            case .general: GeneralSettingsView()
            case .applications: ApplicationsSettingsView()
            case .systemSettings: SystemSettingsSettingsView()
            case .systemActions: SystemActionsSettingsView()
            case .commands: CommandsSettingsView()
            case .quicklinks: QuicklinksSettingsView()
            case .appleShortcuts: AppleShortcutsSettingsView()
            case .fallbacks: FallbacksSettingsView()
            case .ai: AISettingsView()
            case .quickActions: QuickActionsSettingsView()
            case .dictation: DictationSettingsView()
            case .fileSearch: FileSearchSettingsView()
            case .notes: NotesSettingsView()
            case .snippets: SnippetsSettingsView()
            case .navigation: NavigationSettingsView()
            case .windowManagement: WindowManagementSettingsView()
            case .clipboard: ClipboardSettingsView()
            case .emoji: EmojiSettingsView()
            case .calendar: CalendarSettingsView()
            case .extensions: ExtensionsSettingsView()
            case .permissions: PermissionsSettingsView()
            case .backup: BackupSettingsView()
            case .about: AboutView()
            case .shortcuts: ShortcutsSettingsView()  // Fork: Shortcuts overview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One host for every pane, above their scroll views so a callout is never clipped.
        .shortcutRecorderPopoverHost()
        .task(id: navigation.tab) { await present(navigation.tab) }
    }

    private func present(_ tab: SettingsTab) async {
        guard presented != tab else { return }
        if presented != nil {
            try? await Task.sleep(for: paneDefer())
            guard !Task.isCancelled else { return }
        }
        presented = tab
    }

    /// One frame, or past the next repeat while selections come that fast; a held arrow builds once.
    private func paneDefer() -> Duration {
        let now = ContinuousClock.now
        let repeatWindow = Duration.seconds(NSEvent.keyRepeatInterval * 1.5)
        defer { lastSelection = now }
        return now - lastSelection < repeatWindow ? repeatWindow : Theme.Duration.settingsPaneDefer
    }
}
