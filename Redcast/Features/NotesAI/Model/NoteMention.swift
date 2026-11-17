import Foundation

/// `@note` typed into the composer is a trigger for the note picker, never syntax sent to a model.
enum NoteMention {
    static let token = "@note"
    private static let typed = token + " "

    /// The draft without a just-typed trailing `@note `, or nil when this edit is anything else.
    static func consume(
        old: String, new: String, reservedAtStart: @autoclosure () -> Bool
    ) -> String? {
        guard new.hasSuffix(typed), new.dropLast() == old[...] else { return nil }
        let before = new.dropLast(typed.count)
        guard before.last?.isWhitespace ?? true else { return nil }
        // At the draft's start an MCP server slugged `note` owns the token as its address.
        if before.allSatisfy({ $0 == " " }), reservedAtStart() { return nil }
        return String(before)
    }
}
