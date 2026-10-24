import Foundation

/// The Shortcuts overview's audit and filters, on the shipped model and real bindings.
@main
struct ShortcutsOverviewTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ description: String, _ condition: Bool) {
        print("\(condition ? "PASS" : "FAIL")  \(description)")
        if !condition { failures += 1 }
    }

    static let command = 0x100
    static let option = 0x800
    static let control = 0x1000

    static func combo(_ key: Int, _ modifiers: Int) -> HotKeyBinding {
        .combo(KeyShortcut(carbonKeyCode: key, carbonModifiers: modifiers))
    }

    static let entries: [ShortcutEntry] = [
        ShortcutEntry(
            id: "notes", name: "Notes", kindLabel: "Command", aliasKey: "notes", alias: "n",
            binding: combo(45, command | option), bindingText: "⌥⌘N"),
        ShortcutEntry(
            id: "github", name: "GitHub › Unread", kindLabel: "GitHub", aliasKey: "github", alias: "N ",
            binding: combo(45, command | option), bindingText: "⌥⌘N", isDisabled: true),
        ShortcutEntry(
            id: "spotlightish", name: "Search Files", kindLabel: "Command", binding: combo(49, command),
            bindingText: "⌘Space"),
        ShortcutEntry(id: "tap", name: "Ask by Voice", kindLabel: "Command", binding: .doubleTap(.command)),
        ShortcutEntry(id: "hold", name: "Dictation", kindLabel: "Global", binding: .doubleModifier(.rightCommand)),
        ShortcutEntry(id: "sig", name: "Signature", kindLabel: "Snippet", keyword: ";sig"),
        ShortcutEntry(id: "sig2", name: "Signature (old)", kindLabel: "Snippet", keyword: ";SIG"),
        ShortcutEntry(id: "plain", name: "Café Menu", kindLabel: "Quicklink", aliasKey: "plain")
    ]

    static func main() {
        audit()
        systemShortcuts()
        filters()
        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func audit() {
        let system = SystemShortcutCatalog.shortcuts(symbolicHotKeys: nil)
        let issues = ShortcutAudit.issues(entries, system: system)
        check(
            "two entries on one chord both get flagged",
            issues["notes"]?.contains(.sharesHotkey(with: "GitHub › Unread")) == true
                && issues["github"]?.contains(.sharesHotkey(with: "Notes")) == true)
        check(
            "a shared alias is flagged, case and spaces aside",
            issues["notes"]?.contains(.sharesAlias(with: "GitHub › Unread")) == true)
        check(
            "a shared snippet keyword is flagged",
            issues["sig"] == [.sharesKeyword(with: "Signature (old)")])
        check("a chord macOS keeps is flagged", issues["spotlightish"] == [.system("Spotlight")])
        check(
            "a double tap and a double side tap of one key conflict",
            issues["tap"]?.contains(.sharesHotkey(with: "Dictation")) == true)
        check("a clean entry has no issue", issues["plain"] == nil)
        check("every issue reads as text", issues.values.flatMap { $0 }.allSatisfy { !$0.text.isEmpty })
    }

    static func systemShortcuts() {
        let defaults = SystemShortcutCatalog.shortcuts(symbolicHotKeys: nil)
        let spotlight = KeyShortcut(carbonKeyCode: 49, carbonModifiers: command)
        check("Spotlight's default chord is known", defaults.contains { $0.shortcut == spotlight })
        check(
            "the app switcher is always known",
            defaults.contains { $0.shortcut == KeyShortcut(carbonKeyCode: 48, carbonModifiers: command) })
        let disabled = SystemShortcutCatalog.shortcuts(symbolicHotKeys: ["64": ["enabled": false]])
        check(
            "a shortcut switched off in System Settings is not flagged",
            !disabled.contains { $0.shortcut == spotlight })
        let moved: [String: Any] = [
            "64": ["enabled": true, "value": ["parameters": [32, 49, 0x80000], "type": "standard"]]
        ]
        let remapped = SystemShortcutCatalog.shortcuts(symbolicHotKeys: moved)
        check(
            "a shortcut the reader moved is flagged where it now is",
            remapped.contains { $0.shortcut == KeyShortcut(carbonKeyCode: 49, carbonModifiers: option) }
                && !remapped.contains { $0.shortcut == spotlight })
        let arrows: [String: Any] = [
            "79": ["enabled": true, "value": ["parameters": [65_535, 123, 0x840000], "type": "standard"]]
        ]
        let spaces = SystemShortcutCatalog.shortcuts(symbolicHotKeys: arrows)
        check(
            "an arrow chord keeps its function flag, as the recorder captures it",
            spaces.contains { $0.shortcut == KeyShortcut(carbonKeyCode: 123, carbonModifiers: control | 0x20000) })
    }

    static func filters() {
        let issues = ShortcutAudit.issues(entries, system: SystemShortcutCatalog.shortcuts(symbolicHotKeys: nil))
        func ids(_ filter: ShortcutFilter, _ query: String = "") -> [String] {
            filter.apply(entries, query: query, issues: issues).map(\.id)
        }
        check("All lists everything", ids(.all).count == entries.count)
        check(
            "With Hotkey lists only bound entries",
            ids(.withHotkey) == ["notes", "github", "spotlightish", "tap", "hold"])
        check("With Alias counts snippet keywords too", ids(.withAlias) == ["notes", "github", "sig", "sig2"])
        check(
            "Conflicts lists every flagged entry",
            Set(ids(.conflicts)) == ["notes", "github", "spotlightish", "tap", "hold", "sig", "sig2"])
        check("Disabled lists what can't run", ids(.disabled) == ["github"])
        check("search matches names", ids(.all, "unread") == ["github"])
        check("search ignores accents", ids(.all, "cafe") == ["plain"])
        check("search matches keycaps", ids(.all, "⌥⌘") == ["notes", "github"])
        check("search matches kinds and keywords", ids(.all, "snippet ;sig") == ["sig", "sig2"])
        check("search and filter combine", ids(.withHotkey, "command") == ["notes", "spotlightish", "tap"])
        check("every filter has a title", ShortcutFilter.allCases.allSatisfy { !$0.title.isEmpty })
    }
}
