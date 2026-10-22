import Foundation

/// What one capture of the frontmost window found; every part is optional but the app itself.
struct ScreenContext: Equatable, Sendable {
    /// The control the caret is in, as Accessibility names it; a secure field never becomes one.
    struct FocusedField: Equatable, Sendable {
        let role: String
        let label: String?
        let value: String?
    }

    let appName: String
    let bundleID: String?
    var windowTitle: String?
    var url: String?
    var selection: String?
    var focusedField: FocusedField?
    /// Readable text in tree order, already normalized by `ScreenTextPolicy`.
    var windowText: [String]
    let capturedAt: Date

    init(
        appName: String, bundleID: String?, windowTitle: String? = nil, url: String? = nil,
        selection: String? = nil, focusedField: FocusedField? = nil, windowText: [String] = [],
        capturedAt: Date
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.url = url
        self.selection = selection
        self.focusedField = focusedField
        self.windowText = windowText
        self.capturedAt = capturedAt
    }

    var isEmpty: Bool {
        windowTitle == nil && url == nil && selection == nil && focusedField == nil
            && windowText.isEmpty
    }
}

/// Which parts of an Accessibility tree count as readable text, and how far a walk may go.
enum ScreenTextPolicy {
    /// Roles whose value or title is prose a reader sees; containers only lead to them.
    static let textRoles: Set<String> = [
        "AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXComboBox"
    ]
    /// Never read, as a role or a subrole: a password is not context.
    static let secureRoles: Set<String> = ["AXSecureTextField"]

    /// A wedged or enormous tree stops here rather than holding the capture open.
    static let maxNodes = 6_000
    static let maxDepth = 64
    static let maxDuration: Duration = .milliseconds(400)

    static func isSecure(role: String?, subrole: String?) -> Bool {
        role.map(secureRoles.contains) == true || subrole.map(secureRoles.contains) == true
    }

    /// A run of one line is kept once: a label and the text inside it often report the same words.
    static func normalized(_ lines: [String]) -> [String] {
        var result: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != result.last else { continue }
            result.append(trimmed)
        }
        return result
    }
}
