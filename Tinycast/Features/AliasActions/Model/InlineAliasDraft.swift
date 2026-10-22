import Foundation

/// The alias typed into a ⌘K row; Return commits it, Escape drops it.
struct InlineAliasDraft: Sendable, Equatable {
    enum Key: Sendable, Equatable { case cancel, commit, deleteBackward, text(String) }
    enum Outcome: Sendable, Equatable { case editing, cancelled, committed(String) }

    private(set) var text: String

    init(saved: String?) {
        text = saved ?? ""
    }

    /// A blank commit clears the alias, by `AliasStore.setAlias`'s own rule.
    mutating func apply(_ key: Key) -> Outcome {
        switch key {
        case .cancel:
            return .cancelled
        case .commit:
            // Trimmed as `AliasField` trims on focus loss; a space inside the alias stays.
            return .committed(text.trimmingCharacters(in: .whitespaces))
        case .deleteBackward:
            if !text.isEmpty { text.removeLast() }
            return .editing
        case .text(let typed):
            text += Self.printable(typed)
            return .editing
        }
    }

    /// Drops controls, DEL and AppKit's function-key range, which arrow keys type.
    static func printable(_ typed: String) -> String {
        var kept = String.UnicodeScalarView()
        kept.append(
            contentsOf: typed.unicodeScalars.filter {
                $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
            })
        return String(kept)
    }
}
