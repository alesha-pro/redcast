import AppKit
// `@preconcurrency` downgrades AX diagnostics: the attribute keys are constant C globals.
@preconcurrency import ApplicationServices

/// The app in front for a dictation: its name at once, its window's title and picture off-main.
enum VoiceAppContextReader {
    /// A hung app costs a dictation this much at most, and never its start.
    private static let timeout: Float = 0.25

    @MainActor
    static func read(_ level: VoiceAppContext.Level) async -> VoiceAppContext? {
        guard level != .off, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = app.localizedName ?? app.bundleIdentifier ?? ""
        return await window(of: app.processIdentifier, named: name, screenshot: level == .screenshot)
    }

    /// The title only with Accessibility already granted, the picture only with Screen Recording.
    @concurrent
    private static func window(
        of pid: pid_t, named name: String, screenshot: Bool
    ) async -> VoiceAppContext? {
        let title = AXIsProcessTrusted() ? focusedWindowTitle(pid) : nil
        var picture: AIImage?
        if screenshot, let png = await WindowScreenshotter.capture(pid: pid, frame: nil),
            let jpeg = await VoiceMediaEncoder.jpeg(
                fromPNG: png, maxEdge: VoiceAppContext.screenshotMaxEdge,
                quality: VoiceAppContext.screenshotQuality)
        {
            picture = AIImage(data: jpeg, mimeType: "image/jpeg")
        }
        return VoiceAppContext(appName: name, windowTitle: title, screenshot: picture)
    }

    private static func focusedWindowTitle(_ pid: pid_t) -> String? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        var window: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window)
                == .success,
            let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(window, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, timeout)
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }
}
