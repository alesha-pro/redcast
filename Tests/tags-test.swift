import Foundation

/// Fork: tags on snippets and quicklinks — frontmatter, the store's column, imports, filter, colour.
@main
@MainActor
struct TagsTests {
    static var failures = 0
    static var passes = 0

    static let fileURL = URL(fileURLWithPath: "/tmp/tags-harness/meeting-notes.md")

    static func main() {
        normalization()
        frontmatterRoundTrip()
        frontmatterTolerance()
        snippetImport()
        quicklinkPersistence()
        quicklinkOlderDatabase()
        quicklinkArchive()
        quicklinkRaycastImport()
        filterAndSearch()
        suggestions()
        drafts()
        colourIsStable()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Spelling

    static func normalization() {
        expect(
            TagList.normalized(["  Work ", "#email", "work", "a,b", "", "  ", "two   words"])
                == ["Work", "email", "a", "b", "two words"],
            "tags trim, drop #, split commas, collapse spaces and keep the first spelling")
        expect(TagList.normalized(["##"]).isEmpty, "a tag of only hashes is no tag")
        expect(
            TagList.normalized([String(repeating: "x", count: 60)]).first?.count == TagList.maximumLength,
            "a long tag is cut to the maximum")
        expect(TagList.normalized(["ta\u{0}b\u{7}"]) == ["tab"], "control characters are dropped")
        expect(TagList.key("Ｗork") == TagList.key("work"), "width and case fold to one key")
    }

    // MARK: - Frontmatter

    static func frontmatterRoundTrip() {
        let snippet = Snippet(
            name: "Meeting Notes", text: "\nBody\n", keyword: "!notes", tags: ["work", "Say \"hi\""])
        let written = SnippetMarkdownSerializer.serialize(snippet)
        expect(
            written == """
                ---
                name: "Meeting Notes"
                keyword: "!notes"
                tags: ["work", "Say \\"hi\\""]
                enabled: true
                show_confirmation: false
                ---

                Body

                """,
            "tags are written after the keyword as a quoted flow list")
        expect(parse(written) == snippet, "a tagged snippet survives a write and a read")

        let untagged = Snippet(name: "Plain", text: "Body")
        let plain = SnippetMarkdownSerializer.serialize(untagged)
        expect(!plain.contains("tags"), "a snippet without tags writes no tags key")
        expect(
            plain == "---\nname: \"Plain\"\nenabled: true\nshow_confirmation: false\n---\nBody",
            "an untagged snippet writes exactly the upstream format")
        expect(parse(plain) == untagged, "an untagged file reads as it always did")
    }

    static func frontmatterTolerance() {
        expect(
            parse("---\nname: \"A\"\ntags: work, email\n---\n")?.tags == ["work", "email"],
            "a bare comma list reads")
        expect(
            parse("---\nTags: [work, 'side project', \"x\"]\n---\n")?.tags == ["work", "side project", "x"],
            "a flow list of bare and quoted items reads, and the key is case-insensitive")
        expect(
            parse("---\ntags:\n  - work\n  - \"email\"\n- third\nname: \"A\"\n---\nBody")?.tags
                == ["work", "email", "third"],
            "a block list reads, and the next key after it still parses")
        expect(parse("---\ntags: \"solo\"\n---\n")?.tags == ["solo"], "one quoted tag reads")
        expect(parse("---\ntags: []\n---\n")?.tags == [], "an empty list is no tags")
        expect(parse("---\ntags: [work, Work, #work]\n---\n")?.tags == ["work"], "repeats collapse")
        expectRejected("---\ntags: [a]\ntags: [b]\n---\n", "a repeated tags key is still refused")
        expectRejected("---\ncategory: \"Work\"\n---\n", "a retired key is still refused")
        expectRejected("---\nshow_hud: true\n---\n", "a renamed key is still refused")
        expectRejected("---\njust text\n---\n", "a line with no key is still refused")

        let foreign = """
            ---
            name: "Mail"
            aliases:
              - greeting
              - hello
            created: 2024-01-02
            enabled: false
            source: "obsidian"
            ---
            Hi
            """
        guard let read = parse(foreign) else { return fail("unknown keys must not stop a file loading") }
        expect(read.name == "Mail" && !read.isEnabled && read.text == "Hi", "known keys still read around them")
        expect(
            read.unknownFrontmatter
                == ["aliases:", "  - greeting", "  - hello", "created: 2024-01-02", "source: \"obsidian\""],
            "unknown keys and their block lines are kept as written")
        var edited = read
        edited.tags = ["work"]
        let rewritten = SnippetMarkdownSerializer.serialize(edited)
        expect(rewritten.contains("aliases:\n  - greeting\n  - hello\ncreated: 2024-01-02"), "they are written back")
        expect(parse(rewritten) == edited, "a file with unknown keys round-trips with its new tags")
    }

    static func snippetImport() {
        let imported = RaycastSnippetImport.parse([
            ["title": "One", "text": "1", "tags": ["work", "Work", "email"]],
            ["title": "Two", "text": "2", "tags": [["name": "home"], ["title": "later"]]],
            ["title": "Three", "text": "3", "tags": "a, b"],
            ["title": "Four", "text": "4"]
        ])
        expect(
            imported.map(\.tags) == [["work", "email"], ["home", "later"], ["a", "b"], []],
            "Raycast snippet tags map when present, in any of the shapes an export uses")
    }

    // MARK: - Quicklinks

    static func quicklinkPersistence() {
        withDirectory { directory in
            let store = QuicklinkStore(directory: directory)
            store.load()
            guard
                let added = try? store.add(
                    Quicklink(name: "Docs", link: "https://example.com", tags: [" work ", "#work", "docs"]))
            else { return fail("a tagged quicklink saves") }
            expect(added.tags == ["work", "docs"], "the store saves normalized tags")
            let copy = try? store.duplicate(id: added.id)
            expect(copy?.tags == ["work", "docs"], "a duplicate keeps the tags")
            var edited = added
            edited.tags = ["home"]
            try? store.update(edited)

            let reopened = QuicklinkStore(directory: directory)
            reopened.load()
            expect(reopened.quicklink(id: added.id)?.tags == ["home"], "tags survive a reopen")
            expect(reopened.quicklink(id: copy?.id ?? UUID())?.tags == ["work", "docs"], "each row has its own")
        }
    }

    static func quicklinkOlderDatabase() {
        withDirectory { directory in
            let database = directory.appendingPathComponent("quicklinks.sqlite3")
            sqlite(
                database,
                """
                CREATE TABLE quicklinks(id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, link TEXT NOT NULL,
                  open_with TEXT, icon TEXT, in_root_search INTEGER NOT NULL DEFAULT 1, pinned_at REAL,
                  created_at REAL NOT NULL, is_enabled INTEGER NOT NULL DEFAULT 1);
                INSERT INTO quicklinks(id, name, link, created_at)
                  VALUES('6F9619FF-8B86-D011-B42D-00C04FC964FF', 'Old', 'https://old.example', 0);
                """)
            let store = QuicklinkStore(directory: directory)
            store.load()
            expect(store.isAvailable, "a database from before tags still opens")
            guard var old = store.quicklinks.first else { return fail("its row still loads") }
            expect(old.tags.isEmpty, "a row from before tags has none")
            old.tags = ["legacy"]
            expect((try? store.update(old)) != nil, "the added column takes a tag")
            let reopened = QuicklinkStore(directory: directory)
            reopened.load()
            expect(reopened.quicklinks.first?.tags == ["legacy"], "and keeps it")
            sqlite(database, "UPDATE quicklinks SET tags = 'a, b'")
            reopened.load()
            expect(reopened.quicklinks.first?.tags == ["a", "b"], "a column that isn't JSON reads as a list")
        }
    }

    static func quicklinkArchive() {
        let tagged = Quicklink(name: "Docs", link: "https://example.com", tags: ["work"])
        guard let data = try? QuicklinkArchive.encode([tagged]),
            let decoded = try? QuicklinkArchive.decode(data)
        else { return fail("a tagged export encodes and decodes") }
        expect((String(bytes: data, encoding: .utf8) ?? "").contains("\"tags\""), "an export writes tags")
        expect(decoded.first?.tags == ["work"], "an import reads them back")

        let older = Data(#"{"version":1,"quicklinks":[{"name":"Old","link":"https://old.example"}]}"#.utf8)
        expect((try? QuicklinkArchive.decode(older))?.first?.tags == [], "an export from before tags imports")
        let odd = Data(#"[{"name":"Odd","link":"https://odd.example","tags":"not a list"}]"#.utf8)
        expect((try? QuicklinkArchive.decode(odd))?.first?.tags == [], "a malformed tags value costs only itself")

        let merged = QuicklinkArchive.merge(
            [Quicklink(name: "New", link: "https://new.example", tags: ["#a", "A", "b"])], into: [])
        expect(merged.additions.first?.tags == ["a", "b"], "a merge keeps the tags, normalized")
    }

    static func quicklinkRaycastImport() {
        let parsed = RaycastQuicklinkImport.parse(
            [
                "quicklinks": [
                    ["name": "Search", "link": "https://s.example?q={Query}", "tags": ["web", "search"]],
                    ["name": "Plain", "link": "https://p.example"]
                ]
            ],
            bundleIDForAppPath: { _ in nil })
        expect(parsed.map(\.tags) == [["web", "search"], []], "Raycast quicklink tags map when present")
    }

    // MARK: - Filter and search

    static func filterAndSearch() {
        let rows = [("Mail", ["work", "email"]), ("Home", ["home"]), ("Bare", [])]
        let filtered = TagList.filter(rows, by: "WORK") { $0.1 }
        expect(filtered.map(\.0) == ["Mail"], "the ⌘P filter keeps rows with the tag, any case")
        expect(TagList.filter(rows, by: nil) { $0.1 }.count == 3, "no filter keeps every row")

        expect(TagList.row(matching: "mai", texts: ["Mail"], tags: []), "a query still finds a name")
        expect(TagList.row(matching: "ema", texts: ["Mail"], tags: ["email"]), "a query finds a tag")
        expect(!TagList.row(matching: "zzz", texts: ["Mail", nil], tags: ["email"]), "nothing else matches")
        expect(TagList.row(matching: "#wo", texts: ["Mail"], tags: ["work"]), "#prefix finds by tag")
        expect(!TagList.row(matching: "#ail", texts: ["Mail"], tags: ["work"]), "#… never finds by name")
        expect(!TagList.row(matching: "#or", texts: [], tags: ["work"]), "#… matches the start of a tag")
        expect(TagList.row(matching: "#", texts: [], tags: ["work"]), "a bare # lists tagged rows")
        expect(!TagList.row(matching: "#", texts: [], tags: []), "and not untagged ones")

        expect(
            TagList.library([["b", "Work"], ["work", "a"], ["Item 10", "Item 2"]])
                == ["a", "b", "Item 2", "Item 10", "Work"],
            "the library lists each tag once, sorted as people read numbers")
    }

    static func suggestions() {
        let library = ["email", "home", "work", "workshop", "network"]
        expect(
            TagList.suggestions(for: "wo", from: library, excluding: []) == ["work", "workshop", "network"],
            "prefix matches come first, then the rest that contain the text")
        expect(
            TagList.suggestions(for: "WO", from: library, excluding: ["Work"]) == ["workshop", "network"],
            "chosen tags are never suggested")
        expect(
            TagList.suggestions(for: "", from: library, excluding: [], limit: 2) == ["email", "home"],
            "an empty field suggests the library, capped")
    }

    static func drafts() {
        var draft = TagDraft(["work"])
        draft.text = "email, home,"
        expect(draft.tags == ["work", "email", "home"] && draft.text.isEmpty, "a comma makes chips")
        draft.text = "next"
        expect(draft.committed == ["work", "email", "home", "next"], "a save keeps the unfinished tag")
        expect(draft.commitText() && draft.text.isEmpty, "↵ makes a chip of the text")
        expect(!draft.commitText(), "↵ on an empty field makes nothing")
        expect(draft.removeLast() && draft.tags.last == "home", "⌫ on an empty field takes the last chip")
        draft.text = "x"
        expect(!draft.removeLast(), "⌫ with text in the field deletes text, not a chip")
        draft.remove("WORK")
        expect(draft.tags == ["email", "home"], "a chip's × removes it whatever the case")
        draft.add("Email")
        expect(draft.tags == ["email", "home"] && draft.text.isEmpty, "adding a tag already there changes nothing")
    }

    // MARK: - Colour

    static func colourIsStable() {
        let pinned: [String: RaycastHue] = [
            "work": RaycastHue.tag("work"), "email": RaycastHue.tag("email"), "home": RaycastHue.tag("home")
        ]
        expect(RaycastHue.tag("Work") == RaycastHue.tag("work"), "a tag's colour ignores its case")
        expect(RaycastHue.tag("ｗｏｒｋ") == RaycastHue.tag("work"), "and its width")
        expect(pinned == expectedHues, "the hash gives the same colours on every launch and Mac")
        let spread = Set((0..<64).map { RaycastHue.tag("tag \($0)") })
        expect(spread.isSubset(of: Set(RaycastHue.agentChoices)), "tags only wear the curated palette")
        expect(!spread.contains(.gray), "grey stays Tinycast's own")
        expect(spread.count == RaycastHue.agentChoices.count, "the hash reaches every colour")
    }

    /// FNV-1a, pinned: a changed hash would recolour every tag the reader already knows.
    static let expectedHues: [String: RaycastHue] = ["work": .magenta, "email": .orange, "home": .green]

    // MARK: - Helpers

    static func parse(_ content: String) -> Snippet? {
        try? SnippetMarkdownSerializer.parse(content: content, fileURL: fileURL)
    }

    static func expectRejected(_ content: String, _ label: String) {
        expect(parse(content) == nil, label)
    }

    static func withDirectory(_ body: (URL) -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-tags-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        body(directory)
    }

    static func sqlite(_ database: URL, _ sql: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = [database.path, sql]
        guard (try? task.run()) != nil else { return fail("could not run sqlite3") }
        task.waitUntilExit()
        if task.terminationStatus != 0 { fail("sqlite3 failed: \(sql.prefix(60))") }
    }

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            passes += 1
        } else {
            fail(label)
        }
    }

    static func fail(_ label: String) {
        print("FAIL: \(label)")
        failures += 1
    }
}
