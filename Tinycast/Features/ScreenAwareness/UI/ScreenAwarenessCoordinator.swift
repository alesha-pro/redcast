import AppKit

/// The one funnel for a capture: the shortcut and the launcher row both read the same window.
@MainActor
final class ScreenAwarenessCoordinator {
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let hotKeys: HotKeyManager
    private let paletteCoordinator: PaletteCoordinator
    private unowned let core: AppCore

    /// A second press while one capture is still reading would stage the window twice.
    private var capturing: Task<Void, Never>?

    init(
        settings: AppSettings, appIndex: AppIndex, hotKeys: HotKeyManager,
        paletteCoordinator: PaletteCoordinator, core: AppCore
    ) {
        self.settings = settings
        self.appIndex = appIndex
        self.hotKeys = hotKeys
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    private var isActive: Bool { settings.aiEnabled && settings.screenAwarenessEnabled }

    /// The row leaves the launcher with the switch; the Carbon binding stays, and does nothing.
    func applyEnabled() {
        appIndex.setCommandsVisible([.askAboutScreen], isActive)
        if !isActive {
            capturing?.cancel()
            capturing = nil
        }
    }

    /// Enabling is consent, and the only place Accessibility is asked for on this feature's behalf.
    func setEnabled(_ enabled: Bool) {
        guard enabled != settings.screenAwarenessEnabled else { return }
        guard enabled else {
            settings.screenAwarenessEnabled = false
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.confirm(
                    title: String(localized: "Enable Screen Awareness?"),
                    message: String(
                        localized: """
                            Ask About Screen reads the window in front of you — its text, the field \
                            you are typing in and, if you allow it, a screenshot — and attaches it \
                            to Quick AI. Nothing is read until you run the command.
                            """),
                    symbol: CommandID.askAboutScreen.sfSymbol,
                    confirmTitle: String(localized: "Continue"), tone: .neutral,
                    confirmRole: .standard)
            else { return }
            settings.screenAwarenessEnabled = true
            Permissions.ensureAccessibility()
            offerShortcutIfNeeded()
        }
    }

    /// Raycast's gesture, offered once. Runs after `hotKeys.start`, before which nothing is bound.
    func offerShortcutIfNeeded() {
        guard isActive, !settings.screenAwarenessShortcutOffered else { return }
        settings.screenAwarenessShortcutOffered = true
        let action = HotKeyAction.command(.askAboutScreen)
        let suggested = HotKeyBinding.doubleModifier(.rightCommand)
        guard hotKeys.binding(for: action) == nil,
            hotKeys.conflictOwner(of: suggested, excluding: action) == nil
        else { return }
        hotKeys.setBinding(suggested, for: action)
    }

    /// Asking happens in the gesture that wants the picture, as Accessibility's does above.
    func setScreenshotEnabled(_ enabled: Bool) {
        settings.screenAwarenessScreenshot = enabled
        if enabled, !ScreenRecordingAccess.isGranted { ScreenRecordingAccess.request() }
    }

    /// What one read of a window found, shared with Ask by Voice.
    struct Capture: Sendable {
        let context: ScreenContext
        let screenshot: Data?
    }

    func askAboutScreen() {
        guard isActive, capturing == nil, let target = captureTarget() else { return }
        guard Permissions.isAccessibilityTrusted() else {
            reportMissingAccessibility()
            return
        }
        let wantsScreenshot = settings.screenAwarenessScreenshot
        capturing = Task { [weak self] in
            guard let self else { return }
            let capture = await self.capture(target, screenshot: wantsScreenshot)
            guard !Task.isCancelled else { return }
            self.capturing = nil
            guard let capture else { return }
            self.present(capture.context, screenshot: capture.screenshot, wantedScreenshot: wantsScreenshot)
        }
    }

    /// Behind the palette when it is open; Tinycast itself is refused with a HUD.
    func captureTarget() -> NSRunningApplication? {
        let target =
            paletteCoordinator.isVisible
            ? paletteCoordinator.targetApp : NSWorkspace.shared.frontmostApplication
        guard let target, target.bundleIdentifier != Bundle.main.bundleIdentifier else {
            core.showMessage(
                String(localized: "Switch to the window you want to ask about first."),
                tone: .neutral)
            return nil
        }
        return target
    }

    /// nil when cancelled or refused; a refusal has shown its dialog by then.
    func capture(_ target: NSRunningApplication, screenshot wantsScreenshot: Bool) async -> Capture? {
        let selection = AccessibilityText.selection(in: target)
        let pid = target.processIdentifier
        let name = target.localizedName ?? target.bundleIdentifier ?? String(localized: "App")
        let bundleID = target.bundleIdentifier
        let reading = await Task.detached(priority: .userInitiated) {
            ScreenContextReader.read(
                pid: pid, appName: name, bundleID: bundleID, selection: selection, now: Date())
        }.value
        let screenshot =
            wantsScreenshot ? await WindowScreenshotter.capture(pid: pid, frame: reading.windowFrame) : nil
        guard !Task.isCancelled else { return nil }
        guard !reading.accessibilityRefused else {
            // Trusted yet refused: the app remembers a refusal from before the grant, not us.
            if Permissions.isAccessibilityTrusted() {
                reportRefusal(by: name)
            } else {
                reportMissingAccessibility()
            }
            return nil
        }
        return Capture(context: reading.context, screenshot: screenshot)
    }

    /// The window's text as a document and its picture, as a chat stages them; Ask by Voice's too.
    func attachments(for capture: Capture) -> [ChatAttachmentReader.Staged] {
        let text = ScreenContextFormatter.markdown(
            capture.context, maxBytes: AIAttachmentBudget.maxInlinedTextBytes, timeZone: .current,
            hasScreenshot: capture.screenshot != nil)
        let name = ScreenContextFormatter.attachmentName(for: capture.context)
        var items = [
            ChatAttachmentReader.Staged(
                payload: .document(
                    AIDocument(
                        data: Data(text.utf8),
                        mimeType: AIAttachmentPolicy.mimeType(forFileName: name), name: name)),
                name: name, preview: nil)
        ]
        if let screenshot = capture.screenshot,
            case .staged(let image) = ChatAttachmentReader.image(screenshot)
        {
            items.append(image)
        }
        return items
    }

    private func present(_ context: ScreenContext, screenshot: Data?, wantedScreenshot: Bool) {
        let items = attachments(for: Capture(context: context, screenshot: screenshot))
        switch settings.screenAwarenessDestination {
        case .aiChat:
            if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
            core.aiChatCoordinator.showStaging(items)
        case .quickAI:
            core.quickAICoordinator.showStaging(items)
        }
        // Missing permission is worth one line; a capture that simply had no picture is not.
        if wantedScreenshot, screenshot == nil, !ScreenRecordingAccess.isGranted {
            core.showMessage(
                String(localized: "No screenshot: allow Screen Recording for Tinycast in System Settings."),
                tone: .neutral)
        }
    }

    private func reportRefusal(by app: String) {
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.reportFailure(
                    title: String(localized: "\(app) isn't answering Screen Awareness"),
                    message: String(
                        localized: """
                            \(app) refused Tinycast's Accessibility requests, usually because it \
                            remembers a refusal from before the permission was granted. Quit and \
                            reopen \(app). If it still refuses, switch Tinycast off and on in \
                            Accessibility.
                            """),
                    symbol: CommandID.askAboutScreen.sfSymbol,
                    recovery: String(localized: "Open System Settings"))
            else { return }
            Permissions.openAccessibilitySettings()
        }
    }

    func reportMissingAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.reportFailure(
                    title: String(localized: "Screen Awareness can't read this window"),
                    message: String(
                        localized: """
                            Tinycast needs the Accessibility permission to read the window in front \
                            of you. If Tinycast is already listed, switch it off and on again — a \
                            rebuilt app keeps a stale entry.
                            """),
                    symbol: CommandID.askAboutScreen.sfSymbol,
                    recovery: String(localized: "Open System Settings"))
            else { return }
            Permissions.openAccessibilitySettings()
        }
    }
}
