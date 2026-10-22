import Foundation

@main
@MainActor
struct AliasActionsTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        anExactAliasJumps()
        onlyAnExactAliasAtTheEndJumps()
        aBackslashEscapesTheSpace()
        aSharedAliasFallsThrough()
        appsAndSettingsKeepSearching()
        argumentsAreAskedForFirst()
        aViewCommandOpensToSearchInside()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static let aliases = ["com.apple.Safari": "sf", "quicklink:gh": "gh", "ext:brew": "brew"]

    static func anExactAliasJumps() {
        expect(
            AliasJump.decide(query: "gh", caretAtEnd: true, aliases: aliases)
                == .jump(entryKey: "quicklink:gh"),
            "an alias typed exactly, caret at the end, jumps to its entry")
    }

    static func onlyAnExactAliasAtTheEndJumps() {
        expect(
            AliasJump.decide(query: "GH", caretAtEnd: true, aliases: aliases) == .ignore,
            "the match is case-sensitive, so Shift turns an alias back into a search")
        expect(
            AliasJump.decide(query: "gh", caretAtEnd: false, aliases: aliases) == .ignore,
            "a caret inside the query types a space")
        expect(
            AliasJump.decide(query: "", caretAtEnd: true, aliases: aliases) == .ignore,
            "an empty query types a space")
        expect(
            AliasJump.decide(query: "g", caretAtEnd: true, aliases: ["key": "g h"]) == .ignore,
            "an alias with an inner space never matches a shorter prefix of it")
        expect(
            AliasJump.decide(query: "g h", caretAtEnd: true, aliases: ["key": "g h"])
                == .jump(entryKey: "key"),
            "while the whole of it still jumps")
    }

    static func aBackslashEscapesTheSpace() {
        expect(
            AliasJump.decide(query: "foo\\", caretAtEnd: true, aliases: aliases)
                == .escapeSpace(query: "foo "),
            "a trailing backslash becomes the space")
        expect(
            AliasJump.decide(query: "foo\\", caretAtEnd: true, aliases: ["key": "foo\\"])
                == .escapeSpace(query: "foo "),
            "even when the backslash is part of an alias")
    }

    static func aSharedAliasFallsThrough() {
        expect(
            AliasJump.decide(query: "x", caretAtEnd: true, aliases: ["one": "x", "two": "x"])
                == .ignore,
            "two entries with one alias type a space rather than pick one by chance")
    }

    static func appsAndSettingsKeepSearching() {
        expect(
            AliasJump.target(for: .init(kind: .application)) == nil,
            "an application keeps searching")
        expect(
            AliasJump.target(for: .init(kind: .systemSettings, headerFieldsBuilt: true)) == nil,
            "a settings pane keeps searching")
    }

    static func argumentsAreAskedForFirst() {
        expect(
            AliasJump.target(for: .init(kind: .quicklink, argumentCount: 2)) == .pendingArguments,
            "a quicklink with placeholders waits for its fields")
        expect(
            AliasJump.target(for: .init(kind: .customCommand)) == .activate,
            "a custom command without arguments or fields runs")
        expect(
            AliasJump.target(
                for: .init(
                    kind: .extensionCommand, argumentCount: 1, hasRequiredArgument: true,
                    isViewCommand: true)) == .pendingArguments,
            "an extension view command with a required argument waits for it")
        expect(
            AliasJump.target(for: .init(kind: .other, headerFieldsBuilt: true)) == .firstField,
            "a built-in command whose fields are already built focuses the first")
        expect(
            AliasJump.target(for: .init(kind: .other)) == .activate, "anything else runs")
    }

    static func aViewCommandOpensToSearchInside() {
        expect(
            AliasJump.target(
                for: .init(kind: .extensionCommand, argumentCount: 2, isViewCommand: true))
                == .activate,
            "a view command with only optional arguments opens, to search inside it")
        expect(
            AliasJump.target(for: .init(kind: .extensionCommand, argumentCount: 1)) == .pendingArguments,
            "a no-view command with an optional argument still asks for it")
    }
}
