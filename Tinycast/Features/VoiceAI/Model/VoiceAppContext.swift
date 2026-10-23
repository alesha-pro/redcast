import Foundation

/// The app in front as a cloud dictation starts: read as the capsule shows, sent once, never kept.
struct VoiceAppContext: Equatable, Sendable {
    /// How much of it Settings lets a dictation send.
    enum Level: String, CaseIterable, Sendable {
        case off
        case title
        case screenshot
    }

    static let maxLineLength = 200
    /// Small enough to keep the request light, large enough for a window's names to stay legible.
    static let screenshotMaxEdge = 1_280
    static let screenshotQuality = 0.6

    let appName: String
    let windowTitle: String?
    let screenshot: AIImage?

    /// nil without an app name; each line is folded onto one line and capped.
    init?(appName: String, windowTitle: String?, screenshot: AIImage? = nil) {
        guard let name = Self.line(appName) else { return nil }
        self.appName = name
        self.windowTitle = windowTitle.flatMap(Self.line)
        self.screenshot = screenshot
    }

    private static func line(_ text: String) -> String? {
        let folded = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !folded.isEmpty else { return nil }
        return folded.count <= maxLineLength ? folded : String(folded.prefix(maxLineLength - 1)) + "…"
    }
}
