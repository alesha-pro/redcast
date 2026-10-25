import AppKit
// `@preconcurrency` downgrades AX diagnostics: the attribute keys are constant C globals.
@preconcurrency import ApplicationServices

/// `screen_context`: the text of the window behind Tinycast, read when called and kept nowhere.
struct ScreenAgentTools: AgentToolProvider {
    static let name = "screen_context"
    /// Under the executor's 28 KB, so the formatter's own cut is the one that says where it stopped.
    static let maxBytes = 24 * 1_024

    /// The app whose window is read, found without any observer or Screen Recording.
    struct Target: Sendable {
        let pid: pid_t
        let name: String
        let bundleID: String?
    }

    /// Asked again per call: the feature can be switched off while a turn runs.
    let isEnabled: @Sendable () async -> Bool
    var isTrusted: @Sendable () -> Bool = { AXIsProcessTrusted() }
    var target: @Sendable () -> Target? = { Self.windowBehindTinycast() }
    var read: @Sendable (Target) -> ScreenContextReader.Reading = { Self.reading($0) }

    /// Only a turn the user sent: in a schedule or a sub-agent the window in front is chance.
    func specs(for turn: AgentTurn) -> [AgentToolSpec] {
        guard turn.isUserTurn else { return [] }
        return [
            AgentToolSpec(
                tool: Self.definition(origin: turn.profile.name), family: .screen, risk: .personal,
                concurrent: true)
        ]
    }

    func run(_ call: AIToolCall, in context: AgentToolContext) async -> AIToolResult {
        guard context.turn.isUserTurn else {
            return .failure(call.id, "The screen is read only in a chat the user is writing in.")
        }
        guard await isEnabled() else {
            return .failure(call.id, "Screen Awareness is off in Redcast, so the screen cannot be read.")
        }
        guard isTrusted() else {
            return .failure(
                call.id,
                "Redcast lacks the Accessibility permission, so it cannot read the screen. Tell the user.")
        }
        guard let target = target() else {
            return .failure(call.id, "No window of another app is on screen.")
        }
        let request = AgentConsentRequest(
            summary: String(localized: "Read the window of \(target.name)"), detail: "")
        guard await context.consent(request) else {
            return .failure(call.id, "The user declined this. Ask what they would like instead.")
        }
        let reading = read(target)
        guard !reading.accessibilityRefused else {
            return .failure(call.id, "\(target.name) refused to be read; quitting and reopening it may help.")
        }
        let text = ScreenContextFormatter.markdown(
            reading.context, maxBytes: Self.maxBytes, timeZone: .current, hasScreenshot: false)
        return AIToolResult(callID: call.id, content: text, isError: false)
    }

    static func definition(origin: String) -> AITool {
        AITool(
            name: name,
            description:
                "Read what the user has on screen behind Redcast: the app, window title, page URL, "
                + "selected text, the field being typed in and the window's readable text. Text only, "
                + "read now. Use it when the user refers to what they are looking at.",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            origin: origin, title: name)
    }

    /// Front to back: the first normal window of a regular app that is not Tinycast.
    static func windowBehindTinycast() -> Target? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let listing = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        for window in listing {
            guard window[kCGWindowLayer as String] as? Int == 0,
                (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular
            else { continue }
            let name = app.localizedName ?? app.bundleIdentifier ?? String(localized: "App")
            return Target(pid: pid, name: name, bundleID: app.bundleIdentifier)
        }
        return nil
    }

    /// The same read Ask About Screen makes, minus the picture; the selection never borrows ⌘C.
    static func reading(_ target: Target) -> ScreenContextReader.Reading {
        let selection = NSRunningApplication(processIdentifier: target.pid)
            .flatMap(AccessibilityText.selection(in:))
        return ScreenContextReader.read(
            pid: target.pid, appName: target.name, bundleID: target.bundleID, selection: selection,
            now: Date())
    }
}
