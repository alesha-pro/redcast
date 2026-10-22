import Foundation

/// The Claude app's Code sessions and `claude://code/continue`, as Claude.app 2.42304 handles them.
enum ClaudeAppRoute {
    /// The app writes a record compactly, and its two ids end within the first 120 bytes.
    static let headLength = 1_024
    static let recordPrefix = "local_"

    /// What the app's handler accepts: `local_` and 1–64 letters, digits or `-`.
    static func isDesktopID(_ id: String) -> Bool {
        id.hasPrefix(recordPrefix) && AgentResumeCommand.isSafeID(String(id.dropFirst(recordPrefix.count)))
    }

    /// The record's own id when its `cliSessionId` is `transcriptID`, the CLI transcript it runs on.
    static func desktopID(inHead head: Data, transcriptID: String) -> String? {
        guard value(of: "cliSessionId", in: head) == transcriptID,
            let id = value(of: "sessionId", in: head), isDesktopID(id)
        else { return nil }
        return id
    }

    /// Opens that session; the app opens only one that is not archived, else its Code home.
    static func continueURL(desktopID: String) -> URL? {
        guard isDesktopID(desktopID) else { return nil }
        return URL(string: "claude://code/continue?session=" + desktopID)
    }

    /// A string member written without spaces; ids hold no escapes, so the next quote ends one.
    private static func value(of key: String, in head: Data) -> String? {
        guard let range = head.firstRange(of: Data(("\"" + key + "\":\"").utf8)) else { return nil }
        let rest = head[range.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(bytes: rest[..<end], encoding: .utf8)
    }
}
