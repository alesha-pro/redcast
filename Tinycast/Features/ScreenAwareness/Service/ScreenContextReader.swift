import AppKit
import Carbon.HIToolbox
import OSLog
// `@preconcurrency` downgrades AX diagnostics: the attribute keys are constant C globals.
@preconcurrency import ApplicationServices

/// The frontmost window through Accessibility, read off-main against `ScreenTextPolicy`'s budget.
nonisolated enum ScreenContextReader {
    struct Reading: Sendable {
        var context: ScreenContext
        /// Accessibility's frame, in the window server's top-left coordinates, to find its picture.
        var windowFrame: CGRect?
        /// A stale grant after a reinstall: trusted on paper, every call answers disabled.
        var accessibilityRefused = false
    }

    private static let timeout: Float = 1
    /// Chromium builds its tree only after `AXManualAccessibility`, so an empty read tries again.
    private static let retryDelays: [Duration] = [.milliseconds(150), .milliseconds(300)]
    private static let logger = Logger(subsystem: "com.tinycast", category: "ScreenAwareness")
    /// One editor can hold a whole file in a single value; a line past this is cut.
    private static let maxLineLength = 4_000
    private static let walkedAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXChildrenAttribute
    ]

    static func read(
        pid: pid_t, appName: String, bundleID: String?, selection: String?, now: Date
    ) -> Reading {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        // Chromium builds its tree only once asked, so Chrome and Electron answer nothing until this.
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var context = ScreenContext(
            appName: appName, bundleID: bundleID, selection: selection, capturedAt: now)
        let started = ContinuousClock.now
        var attempt = 0
        var reading = Reading(context: context, windowFrame: nil)
        while true {
            attempt += 1
            context.focusedField = focusedField(in: application)
            let lookup = window(of: application)
            guard let window = lookup.element else {
                let errors = lookup.errors
                logger.notice(
                    "attempt \(attempt): no window, AX \(errors.focused) \(errors.main) \(errors.windows)")
                reading = Reading(context: context, windowFrame: nil)
                // Waiting cannot fix a refused grant, so the reader hears about it at once instead.
                if lookup.isRefused {
                    reading.accessibilityRefused = true
                    break
                }
                guard let delay = retryDelay(after: attempt) else { break }
                sleep(for: delay)
                continue
            }
            AXUIElementSetMessagingTimeout(window, timeout)
            context.windowTitle = string(window, kAXTitleAttribute)
            let walk = walkText(from: window)
            context.windowText = ScreenTextPolicy.normalized(walk.lines)
            context.url = walk.url
            reading = Reading(context: context, windowFrame: frame(of: window))
            let source = lookup.source
            let lines = context.windowText.count
            logger.notice("attempt \(attempt) via \(source): title \(context.windowTitle != nil)")
            logger.notice(
                "\(walk.visited) nodes, \(walk.failed) failed, \(lines) lines, url \(walk.url != nil), \(walk.stop)")
            // A tree still being built reads as a window with nothing in it.
            guard walk.lines.isEmpty, walk.url == nil, let delay = retryDelay(after: attempt)
            else { break }
            sleep(for: delay)
        }
        let elapsed = started.duration(to: .now).description
        logger.notice("capture took \(elapsed) over \(attempt) attempts")
        return reading
    }

    private struct WindowLookup {
        var element: AXUIElement?
        var source = "none"
        var errors: (focused: Int32, main: Int32, windows: Int32) = (0, 0, 0)

        var isRefused: Bool {
            let disabled = AXError.apiDisabled.rawValue
            return errors.focused == disabled && errors.main == disabled && errors.windows == disabled
        }
    }

    /// Focused, then main, then the first listed: Electron apps often report only the last.
    private static func window(of application: AXUIElement) -> WindowLookup {
        var lookup = WindowLookup()
        let focused = copy(application, kAXFocusedWindowAttribute)
        lookup.errors.focused = focused.error.rawValue
        if let window = focused.element {
            lookup.element = window
            lookup.source = "focused"
            return lookup
        }
        let main = copy(application, kAXMainWindowAttribute)
        lookup.errors.main = main.error.rawValue
        if let window = main.element {
            lookup.element = window
            lookup.source = "main"
            return lookup
        }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &value)
        lookup.errors.windows = status.rawValue
        if let first = (value as? [AXUIElement])?.first {
            lookup.element = first
            lookup.source = "windows"
        }
        return lookup
    }

    private static func retryDelay(after attempt: Int) -> Duration? {
        attempt <= retryDelays.count ? retryDelays[attempt - 1] : nil
    }

    private static func sleep(for delay: Duration) {
        let (seconds, attoseconds) = delay.components
        usleep(useconds_t(seconds * 1_000_000 + attoseconds / 1_000_000_000_000))
    }

    private static func focusedField(in application: AXUIElement) -> ScreenContext.FocusedField? {
        guard let focused = element(application, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, timeout)
        let role = string(focused, kAXRoleAttribute) ?? "AXUnknown"
        let subrole = string(focused, kAXSubroleAttribute)
        // A field typed into under Secure Event Input is a password whatever its role says.
        guard !ScreenTextPolicy.isSecure(role: role, subrole: subrole), !IsSecureEventInputEnabled()
        else { return nil }
        let label =
            string(focused, kAXTitleAttribute) ?? string(focused, kAXDescriptionAttribute)
            ?? string(focused, kAXPlaceholderValueAttribute)
        let value = string(focused, kAXValueAttribute).map(capped)
        guard label != nil || value != nil else { return nil }
        return ScreenContext.FocusedField(role: role, label: label, value: value)
    }

    /// Depth-first in tree order, so the lines read top to bottom the way the window lays them out.
    private struct Walk {
        var lines: [String] = []
        var url: String?
        var visited = 0
        var failed = 0
        var stop = "exhausted"
    }

    private static func walkText(from window: AXUIElement) -> Walk {
        let deadline = ContinuousClock.now + ScreenTextPolicy.maxDuration
        let attributeNames = walkedAttributes as CFArray
        var stack: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var walk = Walk()
        while let (current, depth) = stack.popLast() {
            guard walk.visited < ScreenTextPolicy.maxNodes else {
                walk.stop = "nodes"
                break
            }
            guard ContinuousClock.now < deadline else {
                walk.stop = "time"
                break
            }
            walk.visited += 1
            var values: CFArray?
            guard
                AXUIElementCopyMultipleAttributeValues(current, attributeNames, [], &values)
                    == .success,
                let attributes = values as? [AnyObject], attributes.count == 6
            else {
                walk.failed += 1
                continue
            }
            let role = attributes[0] as? String
            let subrole = attributes[1] as? String
            if ScreenTextPolicy.isSecure(role: role, subrole: subrole) { continue }
            if role == "AXWebArea", walk.url == nil { walk.url = webAreaURL(current) }
            if let role, ScreenTextPolicy.textRoles.contains(role),
                let text = (attributes[2] as? String) ?? (attributes[3] as? String)
                    ?? (attributes[4] as? String)
            {
                walk.lines.append(capped(text))
            }
            guard depth < ScreenTextPolicy.maxDepth,
                let children = attributes[5] as? [AXUIElement]
            else { continue }
            for child in children.reversed() { stack.append((child, depth + 1)) }
        }
        return walk
    }

    private static func webAreaURL(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &value) == .success
        else { return nil }
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = axValue(window, kAXPositionAttribute),
            let sizeValue = axValue(window, kAXSizeAttribute),
            AXValueGetValue(positionValue, .cgPoint, &position),
            AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func capped(_ text: String) -> String {
        text.count <= maxLineLength ? text : String(text.prefix(maxLineLength)) + "…"
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        copy(parent, attribute).element
    }

    private static func copy(
        _ parent: AXUIElement, _ attribute: String
    ) -> (element: AXUIElement?, error: AXError) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(parent, attribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return (nil, status) }
        return (unsafeDowncast(value, to: AXUIElement.self), status)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let text = value as? String
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }
}
