import AppKit
import Carbon.HIToolbox
// `@preconcurrency` downgrades AX diagnostics: the attribute keys are constant C globals.
@preconcurrency import ApplicationServices

/// The frontmost window through Accessibility, read off-main against `ScreenTextPolicy`'s budget.
nonisolated enum ScreenContextReader {
    struct Reading: Sendable {
        var context: ScreenContext
        /// Accessibility's frame, in the window server's top-left coordinates, to find its picture.
        var windowFrame: CGRect?
    }

    private static let timeout: Float = 1
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
        context.focusedField = focusedField(in: application)
        guard
            let window = element(application, kAXFocusedWindowAttribute)
                ?? element(application, kAXMainWindowAttribute)
        else { return Reading(context: context, windowFrame: nil) }
        AXUIElementSetMessagingTimeout(window, timeout)
        context.windowTitle = string(window, kAXTitleAttribute)
        let walk = walkText(from: window)
        context.windowText = ScreenTextPolicy.normalized(walk.lines)
        context.url = walk.url
        return Reading(context: context, windowFrame: frame(of: window))
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
    private static func walkText(from window: AXUIElement) -> (lines: [String], url: String?) {
        let deadline = ContinuousClock.now + ScreenTextPolicy.maxDuration
        let attributeNames = walkedAttributes as CFArray
        var stack: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var lines: [String] = []
        var url: String?
        var visited = 0
        while let (current, depth) = stack.popLast(), visited < ScreenTextPolicy.maxNodes,
            ContinuousClock.now < deadline
        {
            visited += 1
            var values: CFArray?
            guard
                AXUIElementCopyMultipleAttributeValues(current, attributeNames, [], &values)
                    == .success,
                let attributes = values as? [AnyObject], attributes.count == 6
            else { continue }
            let role = attributes[0] as? String
            let subrole = attributes[1] as? String
            if ScreenTextPolicy.isSecure(role: role, subrole: subrole) { continue }
            if role == "AXWebArea", url == nil { url = webAreaURL(current) }
            if let role, ScreenTextPolicy.textRoles.contains(role),
                let text = (attributes[2] as? String) ?? (attributes[3] as? String)
                    ?? (attributes[4] as? String)
            {
                lines.append(capped(text))
            }
            guard depth < ScreenTextPolicy.maxDepth,
                let children = attributes[5] as? [AXUIElement]
            else { continue }
            for child in children.reversed() { stack.append((child, depth + 1)) }
        }
        return (lines, url)
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
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
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
