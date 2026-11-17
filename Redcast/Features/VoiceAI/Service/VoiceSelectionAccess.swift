import AppKit

/// Whether a selection can be written in place; a web page's or a label's cannot.
@MainActor
enum VoiceSelectionAccess {
    static func isWritable(in app: NSRunningApplication) -> Bool {
        guard let element = AccessibilityText.focusedElement(in: app) else { return false }
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return status == .success && settable.boolValue
    }
}
