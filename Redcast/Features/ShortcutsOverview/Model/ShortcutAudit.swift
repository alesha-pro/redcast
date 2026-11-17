import Foundation

/// A chord macOS itself answers, so a binding on it never reaches the app.
struct SystemShortcut: Sendable, Equatable {
    let name: String
    let shortcut: KeyShortcut
}

/// What the overview flags on a row; each names the other side so the reader knows where to look.
enum ShortcutIssue: Sendable, Equatable {
    case sharesHotkey(with: String)
    case sharesAlias(with: String)
    case sharesKeyword(with: String)
    case system(String)

    var text: String {
        switch self {
        case .sharesHotkey(let other): return String(localized: "Same shortcut as \(other)")
        case .sharesAlias(let other): return String(localized: "Same alias as \(other)")
        case .sharesKeyword(let other): return String(localized: "Same keyword as \(other)")
        case .system(let name): return String(localized: "Taken by macOS: \(name)")
        }
    }
}

enum ShortcutAudit {
    static func issues(
        _ entries: [ShortcutEntry], system: [SystemShortcut]
    ) -> [String: [ShortcutIssue]] {
        var found: [String: [ShortcutIssue]] = [:]
        let bound = entries.filter(\.hasHotkey)
        for (index, entry) in bound.enumerated() {
            guard let binding = entry.binding else { continue }
            for other in bound[(index + 1)...] {
                guard let otherBinding = other.binding, binding.conflicts(with: otherBinding) else {
                    continue
                }
                found[entry.id, default: []].append(.sharesHotkey(with: other.name))
                found[other.id, default: []].append(.sharesHotkey(with: entry.name))
            }
            if let shortcut = binding.shortcut, let taken = system.first(where: { $0.shortcut == shortcut }) {
                found[entry.id, default: []].append(.system(taken.name))
            }
        }
        flagDuplicates(entries, by: \.alias, as: ShortcutIssue.sharesAlias, into: &found)
        flagDuplicates(entries, by: \.keyword, as: ShortcutIssue.sharesKeyword, into: &found)
        return found
    }

    /// Two entries under one alias make Alias + Space fall through to search instead of opening.
    private static func flagDuplicates(
        _ entries: [ShortcutEntry], by value: KeyPath<ShortcutEntry, String?>,
        as issue: (String) -> ShortcutIssue, into found: inout [String: [ShortcutIssue]]
    ) {
        var groups: [String: [ShortcutEntry]] = [:]
        for entry in entries {
            guard let raw = entry[keyPath: value] else { continue }
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty { groups[key, default: []].append(entry) }
        }
        for group in groups.values where group.count > 1 {
            for entry in group {
                for other in group where other.id != entry.id {
                    found[entry.id, default: []].append(issue(other.name))
                }
            }
        }
    }
}

/// The chords macOS ships, with the reader's own changes from its symbolic hotkeys applied.
enum SystemShortcutCatalog {
    private static let command = 0x100
    private static let shift = 0x200
    private static let option = 0x800
    private static let control = 0x1000
    private static let function = 0x20000

    private struct Known {
        let id: Int
        let name: String
        let keyCode: Int
        let modifiers: Int
    }

    /// Defaults for the ids macOS turns on out of the box, keyed as `AppleSymbolicHotKeys` keys them.
    private static var defaults: [Known] {
        let screenshot = String(localized: "Screenshot")
        let spaces = String(localized: "Spaces")
        return [
            Known(id: 64, name: String(localized: "Spotlight"), keyCode: 49, modifiers: command),
            Known(id: 65, name: String(localized: "Finder search"), keyCode: 49, modifiers: command | option),
            Known(id: 60, name: String(localized: "Input source"), keyCode: 49, modifiers: control),
            Known(id: 61, name: String(localized: "Input source"), keyCode: 49, modifiers: control | option),
            Known(id: 28, name: screenshot, keyCode: 20, modifiers: command | shift),
            Known(id: 29, name: screenshot, keyCode: 20, modifiers: command | shift | control),
            Known(id: 30, name: screenshot, keyCode: 21, modifiers: command | shift),
            Known(id: 31, name: screenshot, keyCode: 21, modifiers: command | shift | control),
            Known(id: 184, name: screenshot, keyCode: 23, modifiers: command | shift),
            Known(
                id: 32, name: String(localized: "Mission Control"), keyCode: 126, modifiers: control | function),
            Known(
                id: 33, name: String(localized: "Application windows"), keyCode: 125,
                modifiers: control | function),
            Known(id: 79, name: spaces, keyCode: 123, modifiers: control | function),
            Known(id: 81, name: spaces, keyCode: 124, modifiers: control | function),
            Known(id: 36, name: String(localized: "Show Desktop"), keyCode: 103, modifiers: function),
            Known(id: 52, name: String(localized: "Dock hiding"), keyCode: 2, modifiers: command | option),
            Known(id: 27, name: String(localized: "Next window"), keyCode: 50, modifiers: command)
        ]
    }

    /// No setting changes these: the app switcher, Force Quit, Lock Screen and Log Out.
    private static var fixed: [SystemShortcut] {
        [
            .init(
                name: String(localized: "App switcher"),
                shortcut: .init(carbonKeyCode: 48, carbonModifiers: command)),
            .init(
                name: String(localized: "App switcher"),
                shortcut: .init(carbonKeyCode: 48, carbonModifiers: command | shift)),
            .init(
                name: String(localized: "Force Quit"),
                shortcut: .init(carbonKeyCode: 53, carbonModifiers: command | option)),
            .init(
                name: String(localized: "Lock Screen"),
                shortcut: .init(carbonKeyCode: 12, carbonModifiers: command | control)),
            .init(
                name: String(localized: "Log Out"),
                shortcut: .init(carbonKeyCode: 12, carbonModifiers: command | shift))
        ]
    }

    /// `symbolicHotKeys` is `com.apple.symbolichotkeys`' `AppleSymbolicHotKeys`, nil when unreadable.
    static func shortcuts(symbolicHotKeys: [String: Any]?) -> [SystemShortcut] {
        var result: [SystemShortcut] = []
        for known in defaults {
            let entry = symbolicHotKeys?[String(known.id)] as? [String: Any]
            if entry?["enabled"] as? Bool == false { continue }
            let chord = entry.flatMap(chord) ?? (known.keyCode, known.modifiers)
            result.append(
                .init(name: known.name, shortcut: .init(carbonKeyCode: chord.0, carbonModifiers: chord.1)))
        }
        return result + fixed
    }

    /// `parameters` is `[character, key code, NSEvent modifier flags]`; 65535 means no key.
    private static func chord(_ entry: [String: Any]) -> (Int, Int)? {
        guard let value = entry["value"] as? [String: Any],
            let parameters = value["parameters"] as? [Int], parameters.count >= 3,
            parameters[1] != 65_535
        else { return nil }
        let flags = parameters[2]
        var modifiers = 0
        if flags & 0x20000 != 0 { modifiers |= shift }
        if flags & 0x40000 != 0 { modifiers |= control }
        if flags & 0x80000 != 0 { modifiers |= option }
        if flags & 0x100000 != 0 { modifiers |= command }
        if flags & 0x800000 != 0 { modifiers |= function }
        return (parameters[1], modifiers)
    }
}
