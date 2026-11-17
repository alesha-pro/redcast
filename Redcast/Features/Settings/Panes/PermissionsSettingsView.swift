import AVFoundation
import SwiftUI

struct PermissionsSettingsView: View {
    @Environment(AppCore.self) private var core
    // Remembered: a read is blocking XPC per service, and a default would flash a prompt.
    @State private var status = PermissionStatus.lastRead ?? .read()

    private var accessibilityTrusted: Bool { status.accessibilityTrusted }
    private var fullDiskAccess: Bool { status.fullDiskAccess }
    private var calendarAccess: CalendarAccess { status.calendarAccess }
    private var microphoneAccess: AVAuthorizationStatus { status.microphoneAccess }

    var body: some View {
        Form {
            SettingsPaneHeader(
                tab: .permissions, subtitle: "What macOS allows, and what each permission unlocks.")

            // Fork: one table, so the four read against each other; each row keeps its anchor.
            Section {
                PermissionRow(
                    anchor: .permissionsAccessibility, title: "Accessibility",
                    detail: "Allows pasting and window management.",
                    symbol: "accessibility", hue: GlyphCategory.windows.hue,
                    grant: accessibilityTrusted ? .granted : .missing,
                    help: "Opens Privacy & Security › Accessibility.",
                    action: Permissions.openAccessibilitySettings)
                PermissionRow(
                    anchor: .permissionsFullDiskAccess, title: "Full Disk Access",
                    detail: "Allows File Search and finding protected app leftovers.",
                    symbol: "internaldrive", hue: GlyphCategory.files.hue,
                    grant: fullDiskAccess ? .granted : .missing,
                    help: "Opens Privacy & Security › Full Disk Access.",
                    action: Permissions.openFullDiskAccessSettings)
                PermissionRow(
                    anchor: .permissionsCalendars, title: "Calendars",
                    detail: "Allows joining your next meeting.",
                    symbol: "calendar", hue: GlyphCategory.calendar.hue,
                    grant: calendarGrant,
                    help: calendarAccess == .notDetermined
                        ? "Turns the calendar on, then asks macOS for access."
                        : "Opens Privacy & Security › Calendars.",
                    action: grantCalendar)
                PermissionRow(
                    anchor: .permissionsMicrophone, title: "Microphone",
                    detail: "Allows dictating text.",
                    symbol: "mic", hue: GlyphCategory.voice.hue,
                    grant: microphoneGrant,
                    help: microphoneAccess == .notDetermined
                        ? "Asks macOS for microphone access."
                        : "Opens Privacy & Security › Microphone.",
                    action: grantMicrophone)
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.permissions)
        .pollingPermissions(read: PermissionStatus.read, apply: apply)
    }

    private var calendarGrant: PermissionGrant {
        switch calendarAccess {
        case .granted: .granted
        case .notDetermined: .notAsked
        case .denied: .missing
        }
    }

    private var microphoneGrant: PermissionGrant {
        switch microphoneAccess {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .missing
        }
    }

    /// Settings lists no app TCC was never asked about, so asking is the way in.
    private func grantCalendar() {
        if calendarAccess == .notDetermined {
            core.calendarCoordinator.setCalendarEnabled(true)
        } else {
            Permissions.openCalendarSettings()
        }
    }

    private func grantMicrophone() {
        guard microphoneAccess == .notDetermined else { return Permissions.openMicrophoneSettings() }
        Task {
            _ = await Permissions.requestMicrophoneAccess()
            apply(PermissionStatus.read())
        }
    }

    private func apply(_ read: PermissionStatus) {
        PermissionStatus.lastRead = read
        if read.fullDiskAccess != status.fullDiskAccess { core.fileIndexer.refreshAccess() }
        if read != status { status = read }
    }
}

private struct PermissionStatus: Equatable, Sendable {
    let accessibilityTrusted: Bool
    let fullDiskAccess: Bool
    let calendarAccess: CalendarAccess
    let microphoneAccess: AVAuthorizationStatus

    @MainActor static var lastRead: PermissionStatus?

    @Sendable static func read() -> PermissionStatus {
        PermissionStatus(
            accessibilityTrusted: Permissions.isAccessibilityTrusted(),
            fullDiskAccess: Permissions.hasFullDiskAccess(),
            calendarAccess: Permissions.calendarAccess(),
            microphoneAccess: Permissions.microphoneAccess())
    }
}

private enum PermissionGrant {
    case granted, missing, notAsked

    var title: String {
        switch self {
        case .granted: String(localized: "Granted")
        case .missing: String(localized: "Not granted")
        case .notAsked: String(localized: "Not asked yet")
        }
    }

    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .missing: "exclamationmark.triangle.fill"
        case .notAsked: "questionmark.circle.fill"
        }
    }

    var tone: SettingsStatusBadge.Tone {
        switch self {
        case .granted: .success
        case .missing: .warning
        case .notAsked: .neutral
        }
    }
}

/// One permission: what it is, how it stands, and the one thing to do about it.
private struct PermissionRow: View {
    let anchor: SettingsAnchor
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let symbol: String
    let hue: RaycastHue
    let grant: PermissionGrant
    let help: LocalizedStringResource
    let action: @MainActor () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: Theme.Spacing.lg) {
                SettingsStatusBadge(title: grant.title, symbol: grant.symbol, tone: grant.tone)
                if grant == .granted {
                    Button(action: action) { actionLabel("Open…") }
                        .help(Text(help))
                } else {
                    Button(action: action) { actionLabel("Grant Access…") }
                        .buttonStyle(.borderedProminent)
                        .help(Text(help))
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.lg) {
                GlyphTile(symbol: symbol, hue: hue, size: SettingsListMetrics.iconSize)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    SettingsRowTitle(anchor, title)
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .settingsAnchor(anchor)
    }

    /// Sized to the longer title, so the buttons and the badges before them hold one column.
    private func actionLabel(_ title: LocalizedStringKey) -> some View {
        Text("Grant Access…").hidden().overlay { Text(title) }
    }
}
