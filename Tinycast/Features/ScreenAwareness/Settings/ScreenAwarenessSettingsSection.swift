import Combine
import SwiftUI

/// A section of the AI pane: the feature only exists to feed Quick AI.
struct ScreenAwarenessSettingsSection: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var appSettings

    /// Polled: both grants land in System Settings, which tells the app nothing.
    @State private var isTrusted = Permissions.isAccessibilityTrusted()
    @State private var canRecord = ScreenRecordingAccess.isGranted
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            Toggle(isOn: enabledBinding) {
                SettingsRowTitle(.aiScreenAwareness, "Enable Screen Awareness")
                Text("Ask About Screen attaches the window in front of you to Quick AI.")
            }
            if appSettings.screenAwarenessEnabled, !isTrusted {
                missingGrant(
                    "Accessibility permission required", detail: "Needed to read the window.",
                    open: Permissions.openAccessibilitySettings)
            }
            Picker(selection: destinationBinding) {
                ForEach(ScreenAwarenessDestination.allCases) { destination in
                    Text(title(of: destination)).tag(destination)
                }
            } label: {
                SettingsRowTitle(.aiScreenAwareness, "Open captures in")
                Text("Double-tap right ⌘ to capture, or set another shortcut under Commands.")
            }
            .disabled(!appSettings.screenAwarenessEnabled)
            Toggle(isOn: screenshotBinding) {
                SettingsRowTitle(.aiScreenAwareness, "Include a screenshot")
                Text("Needs Screen Recording. Only models that read images receive it.")
            }
            .disabled(!appSettings.screenAwarenessEnabled)
            if appSettings.screenAwarenessEnabled, appSettings.screenAwarenessScreenshot, !canRecord {
                missingGrant(
                    "Screen Recording permission required",
                    detail: "Without it, captures carry text only.",
                    open: ScreenRecordingAccess.openSettings)
            }
        } header: {
            SettingsSectionHeader(.aiScreenAwareness)
        } footer: {
            Text(
                """
                A capture is saved with the chat like any attachment. Tinycast never captures its \
                own windows, password fields or text typed under secure input.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onReceive(refreshTimer) { _ in
            isTrusted = Permissions.isAccessibilityTrusted()
            canRecord = ScreenRecordingAccess.isGranted
        }
    }

    private func missingGrant(
        _ title: LocalizedStringKey, detail: LocalizedStringKey, open: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: Theme.Size.settingsRowIcon)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .foregroundStyle(.orange)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.lg)
            Button("Open System Settings", action: open)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { appSettings.screenAwarenessEnabled },
            set: { core.screenAwarenessCoordinator.setEnabled($0) })
    }

    private var destinationBinding: Binding<ScreenAwarenessDestination> {
        Binding(
            get: { appSettings.screenAwarenessDestination },
            set: { appSettings.screenAwarenessDestination = $0 })
    }

    private func title(of destination: ScreenAwarenessDestination) -> String {
        switch destination {
        case .aiChat: CommandID.aiChat.name
        case .quickAI: CommandID.quickAI.name
        }
    }

    private var screenshotBinding: Binding<Bool> {
        Binding(
            get: { appSettings.screenAwarenessScreenshot },
            set: { core.screenAwarenessCoordinator.setScreenshotEnabled($0) })
    }
}
