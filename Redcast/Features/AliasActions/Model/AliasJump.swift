import Foundation

/// Raycast's alias jump: an exact alias, then Space, opens its entry. Declined upstream (#1128).
enum AliasJump {
    enum Decision: Sendable, Equatable {
        case ignore
        /// `\` then Space types the space instead: the backslash is replaced.
        case escapeSpace(query: String)
        case jump(entryKey: String)
    }

    enum Target: Sendable, Equatable {
        /// Fields are built a pass later, so the palette focuses the first unanswered one then.
        case pendingArguments
        case firstField
        case activate
    }

    struct Entry: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case application, systemSettings, quicklink, customCommand, extensionCommand, other
        }

        var kind: Kind
        var argumentCount = 0
        var hasRequiredArgument = false
        var isViewCommand = false
        var headerFieldsBuilt = false
    }

    /// Case-sensitive on purpose: `cc` jumps and `CC`, typed with Shift, searches.
    static func decide(query: String, caretAtEnd: Bool, aliases: [String: String]) -> Decision {
        guard caretAtEnd, !query.isEmpty else { return .ignore }
        if query.hasSuffix("\\") { return .escapeSpace(query: String(query.dropLast()) + " ") }
        let keys = aliases.filter { $0.value == query }.map(\.key)
        // Two entries sharing an alias fall through, as upstream's ranking does.
        guard keys.count == 1, let key = keys.first else { return .ignore }
        return .jump(entryKey: key)
    }

    /// Nil keeps Space a space: "tg something" is more often a query than a jump.
    static func target(for entry: Entry) -> Target? {
        switch entry.kind {
        case .application, .systemSettings:
            return nil
        case .extensionCommand where entry.isViewCommand && !entry.hasRequiredArgument:
            return .activate
        default:
            if entry.argumentCount > 0 { return .pendingArguments }
            return entry.headerFieldsBuilt ? .firstField : .activate
        }
    }
}
