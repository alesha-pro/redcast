import Foundation

/// What a call's row says after its tool's name: the command, path, query or address it was given.
enum AgentCallSummary {
    /// A row is one line; past this the argument is cut, and its full text stays in the call.
    static let limit = 140

    /// The argument a person recognises a call by, in this order of preference.
    private static let keys = [
        "command", "cmd", "query", "url", "path", "file_path", "pattern", "name", "skill", "task", "title"
    ]

    /// `run_command: python3 sync.py`, or the bare title when no argument names the call.
    static func title(_ base: String, arguments: String) -> String {
        guard let detail = detail(of: arguments) else { return base }
        return base + ": " + detail
    }

    static func detail(of arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in keys {
            guard let value = object[key], let text = text(of: value) else { continue }
            return clipped(text)
        }
        return nil
    }

    private static func text(of value: Any) -> String? {
        let raw: String
        switch value {
        case let string as String: raw = string
        case let list as [Any]: raw = list.compactMap { $0 as? String }.joined(separator: " ")
        case let number as NSNumber: raw = number.stringValue
        default: return nil
        }
        // Newlines and runs of spaces would break the row; one line reads as the call was made.
        let line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    private static func clipped(_ text: String) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
