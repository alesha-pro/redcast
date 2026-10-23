import Foundation

/// One read the helper is asked for, as the command line both sides agree on.
nonisolated struct DocumentTextRequest: Equatable, Sendable {
    static let command = "document"

    let path: String
    let kind: DocumentKind
    var pages: DocumentPageRange = .all
    /// UTF-8 bytes of text the answer may carry, so its pipe stays bounded.
    let budget: Int

    /// `document <kind> <path> <first> <last, 0 for open> <budget>`, after the helper's own path.
    var arguments: [String] {
        [Self.command, kind.rawValue, path, String(pages.first), String(pages.last ?? 0), String(budget)]
    }

    init(path: String, kind: DocumentKind, pages: DocumentPageRange = .all, budget: Int) {
        self.path = path
        self.kind = kind
        self.pages = pages
        self.budget = budget
    }

    /// Nil for any other command line, so the clipboard's own commands keep their meaning.
    init?(arguments: [String]) {
        guard arguments.count == 6, arguments[0] == Self.command,
            let kind = DocumentKind(rawValue: arguments[1]), !arguments[2].isEmpty,
            let first = Int(arguments[3]), let last = Int(arguments[4]),
            let budget = Int(arguments[5]), budget > 0
        else { return nil }
        self.init(
            path: arguments[2], kind: kind, pages: DocumentPageRange(first: first, last: last > 0 ? last : nil),
            budget: budget)
    }
}
