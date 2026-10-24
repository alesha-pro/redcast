import Foundation

/// One row of the overview: read from the stores that own it, never stored a second time.
struct ShortcutEntry: Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var kindLabel: String
    /// The `AliasStore` key; nil for what has no alias, like the launcher's own shortcut.
    var aliasKey: String?
    var alias: String?
    /// A snippet's expansion keyword, which lives on the snippet rather than in `AliasStore`.
    var keyword: String?
    var binding: HotKeyBinding?
    /// The keycaps as one string, so a search for "⌥⌘" finds what it is bound to.
    var bindingText = ""
    var isDisabled = false

    var hasHotkey: Bool { binding != nil }
    var hasAlias: Bool { !(alias ?? "").isEmpty || !(keyword ?? "").isEmpty }
}

enum ShortcutFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case withHotkey
    case withAlias
    case conflicts
    case disabled

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .withHotkey: return String(localized: "With Hotkey")
        case .withAlias: return String(localized: "With Alias")
        case .conflicts: return String(localized: "Conflicts")
        case .disabled: return String(localized: "Disabled")
        }
    }

    func apply(
        _ entries: [ShortcutEntry], query: String, issues: [String: [ShortcutIssue]]
    ) -> [ShortcutEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { entry in
            guard includes(entry, issues: issues) else { return false }
            return terms.allSatisfy { Self.matches(entry, $0) }
        }
    }

    private func includes(_ entry: ShortcutEntry, issues: [String: [ShortcutIssue]]) -> Bool {
        switch self {
        case .all: return true
        case .withHotkey: return entry.hasHotkey
        case .withAlias: return entry.hasAlias
        case .conflicts: return !(issues[entry.id] ?? []).isEmpty
        case .disabled: return entry.isDisabled
        }
    }

    private static func matches(_ entry: ShortcutEntry, _ term: String) -> Bool {
        [entry.name, entry.kindLabel, entry.alias ?? "", entry.keyword ?? "", entry.bindingText]
            .contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
