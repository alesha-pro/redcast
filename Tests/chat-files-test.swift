import Foundation

@main
@MainActor
struct ChatFilesTests {
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

    static func main() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        mentionsAreFound()
        proseSlashesAreNotPaths()
        toolRowsNameTheirPaths()
        theScreenshotReplyResolves(fixture)
        homeAndAbsolutePathsResolve(fixture)
        relativePathsNeedAFolder(fixture)
        missingItemsStayPlain(fixture)
        callsFillInWhatTheReplyLeftOut(fixture)
        runnableThingsAreOnlyRevealed(fixture)
        theStripIsDedupedAndCapped(fixture)
        eachPathIsLookedUpOnce(fixture)
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Fixture

    /// A temp folder laid out as the owner's agent left it: a post folder of assets and a script.
    struct Fixture {
        let root: String
        let home: String

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appending(path: "chat-files-test-\(UUID().uuidString)").path(percentEncoded: false)
            root = base + "/project"
            home = base + "/home"
            let manager = FileManager.default
            for folder in [
                "\(root)/posts/gpu-unlock-ada/assets", "\(root)/build/Tool.app/Contents", "\(home)/Desktop"
            ] {
                try manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            for file in [
                "posts/gpu-unlock-ada/assets/die-split-yellow.png", "posts/gpu-unlock-ada/assets/card-1-ada.html",
                "posts/gpu-unlock-ada/assets/card-1-ada.png", "posts/gpu-unlock-ada/assets/card-1-ada.jpg",
                "README.md", "render.sh", "deploy.command", "notes/plan.md", "out/report.pdf", "tool", "My Report.pdf"
            ] {
                let path = "\(root)/\(file)"
                try manager.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                manager.createFile(atPath: path, contents: Data("x".utf8))
            }
            manager.createFile(atPath: "\(home)/Desktop/summary.txt", contents: Data("x".utf8))
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(root)/tool")
            try manager.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: "\(root)/posts/gpu-unlock-ada/assets/card-1-ada.png")
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent)
        }

        func stat(_ path: String) -> ChatFileStat? {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
            return ChatFileStat(
                isDirectory: isDirectory.boolValue,
                isExecutable: !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path),
                isPackage: isDirectory.boolValue && path.hasSuffix(".app"))
        }

        func resolve(
            _ reply: String, directory: String? = nil, titles: [String] = [], diffs: [String] = []
        ) -> ChatFileLinks {
            ChatFileResolver.resolve(
                ChatFileRequest(
                    reply: reply, directory: directory, home: home, toolTitles: titles, diffPaths: diffs),
                stat: stat)
        }
    }

    // MARK: - Mentions

    static func mentionsAreFound() {
        let reply = """
            Saved to `posts/card.png` and [the report](out/report.pdf), see /Users/me/Desktop/a.txt.
            Also [home](<~/My Notes/plan.md>), [abs](file:///tmp/x%20y.png) and `Sources/App.swift:42`.
            ```
            cat `fenced.png` /etc/fenced.txt
            ```
            Not paths: `npm run build`, `x == y`, [web](https://example.com/a.png), `rm -rf *`.
            Again `posts/card.png`.
            """
        let mentions = ChatFileMentions.scan(reply)
        expect(
            mentions.map(\.text) == [
                "posts/card.png", "out/report.pdf", "/Users/me/Desktop/a.txt", "~/My Notes/plan.md", "/tmp/x y.png",
                "Sources/App.swift"
            ], "code spans, links and bare paths in reply order, each once, got \(mentions.map(\.text))")
        expect(
            mentions.map(\.form) == [.code, .link, .bare, .link, .link, .code],
            "each mention knows how it was written")
        expect(ChatFileMentions.codeKey("card-1-ada.png") == "card-1-ada.png", "a bare file name is a mention")
        expect(ChatFileMentions.codeKey("posts/gpu/assets/") == "posts/gpu/assets/", "a folder keeps its slash")
        expect(ChatFileMentions.codeKey("v1.2") == "v1.2", "a version reads as a name; only a lookup rejects it")
        expect(ChatFileMentions.codeKey("python3 make.py | tee") == nil, "a pipeline is a command")
        expect(ChatFileMentions.codeKey("--output") == nil, "a flag is no path")
        expect(ChatFileMentions.codeKey("Reply") == nil, "a word is no path")
        expect(ChatFileMentions.linkKey("mailto:a@b.c") == nil, "a mail link is no file")
        expect(ChatFileMentions.linkKey("x-apple.systempreferences:x") == nil, "an app link is no file")
        expect(ChatFileMentions.linkKey("notes/plan.md#todo") == "notes/plan.md", "an anchor is dropped")
    }

    static func proseSlashesAreNotPaths() {
        let text = "Speed in km/s and/or https://site.com/a and ~/Desktop/summary.txt, or /tmp."
        let found = ChatFileMentions.barePaths(in: text).map { String(text[$0]) }
        expect(found == ["~/Desktop/summary.txt", "/tmp"], "only paths that start a word, got \(found)")
        expect(ChatFileMentions.barePaths(in: "/ and ~/ alone").isEmpty, "a lone slash is punctuation")
    }

    static func toolRowsNameTheirPaths() {
        let native = ChatFileMentions.toolPaths("write_file: posts/card.png")
        expect(native.paths == ["posts/card.png"] && native.writes, "a native write names what it wrote")
        let acp = ChatFileMentions.toolPaths("Write /tmp/out/card.png")
        expect(acp.paths == ["/tmp/out/card.png"] && acp.writes, "an ACP write title names its file")
        let command = ChatFileMentions.toolPaths("run_command: python3 render.py --out cards/a.png")
        expect(command.paths == ["render.py", "cards/a.png"] && !command.writes, "a command only touches")
        let cut = ChatFileMentions.toolPaths("read_file: notes/a-very-long-na…")
        expect(cut.paths.isEmpty, "a title cut short names nothing it cut")
    }

    // MARK: - Resolution

    static func theScreenshotReplyResolves(_ fixture: Fixture) {
        let reply = """
            Все ассеты лежат в папке `posts/gpu-unlock-ada/assets/`:

            - `die-split-yellow.png`
            - `card-1-ada.html`
            - `card-1-ada.png`
            - `card-1-ada.jpg`
            """
        let links = fixture.resolve(reply, directory: fixture.root)
        let assets = fixture.root + "/posts/gpu-unlock-ada/assets"
        expect(links.byMention["posts/gpu-unlock-ada/assets/"]?.path == assets, "the folder resolves")
        expect(links.byMention["posts/gpu-unlock-ada/assets/"]?.kind == .folder, "and is a folder")
        expect(
            links.byMention["card-1-ada.png"]?.path == assets + "/card-1-ada.png",
            "a bare name resolves against the folder the reply named")
        expect(links.byMention["card-1-ada.png"]?.kind == .image, "an image is an image despite its +x bit")
        expect(
            links.files.map(\.name) == [
                "assets", "die-split-yellow.png", "card-1-ada.html", "card-1-ada.png", "card-1-ada.jpg"
            ], "the strip lists the folder and its files in reply order, got \(links.files.map(\.name))")
        expect(links.byMention["card-1-ada.html"]?.opens == true, "a page opens in its app")
    }

    static func homeAndAbsolutePathsResolve(_ fixture: Fixture) {
        let links = fixture.resolve(
            "Wrote ~/Desktop/summary.txt and `\(fixture.root)/README.md`, and [it](<\(fixture.root)/My Report.pdf>).")
        expect(
            links.byMention["~/Desktop/summary.txt"]?.path == fixture.home + "/Desktop/summary.txt",
            "a ~ path resolves in the injected home, in a plain chat too")
        expect(links.byMention["\(fixture.root)/README.md"] != nil, "an absolute path resolves without a folder")
        expect(links.byMention["\(fixture.root)/My Report.pdf"] != nil, "a link target with spaces resolves")
    }

    static func relativePathsNeedAFolder(_ fixture: Fixture) {
        let inFolder = fixture.resolve("See `notes/plan.md` and `./notes/../README.md`.", directory: fixture.root)
        expect(
            inFolder.byMention["notes/plan.md"]?.path == fixture.root + "/notes/plan.md",
            "a relative path resolves in the chat's folder")
        expect(
            inFolder.byMention["./notes/../README.md"]?.path == fixture.root + "/README.md",
            "dots fold away")
        expect(fixture.resolve("See `notes/plan.md`.").isEmpty, "a plain chat has no folder to resolve it in")
        let named = fixture.resolve("In `\(fixture.root)/posts/` there is `gpu-unlock-ada/assets/card-1-ada.jpg`.")
        expect(
            named.byMention["gpu-unlock-ada/assets/card-1-ada.jpg"] != nil,
            "a relative path also resolves inside an absolute folder the reply named")
        let bare = fixture.resolve("Start with `README.md`.", directory: fixture.root)
        expect(bare.byMention["README.md"]?.path == fixture.root + "/README.md", "a bare name falls back to the folder")
    }

    static func missingItemsStayPlain(_ fixture: Fixture) {
        let links = fixture.resolve(
            "Planned `missing.png`, /no/such/file.txt and `posts/ghost/`.", directory: fixture.root)
        expect(links.isEmpty, "only what exists becomes a link, got \(links.byMention.keys.sorted())")
    }

    static func callsFillInWhatTheReplyLeftOut(_ fixture: Fixture) {
        let links = fixture.resolve(
            "Done: `report.pdf` is ready.", directory: fixture.root,
            titles: ["run_command: make report --out out/report.pdf", "write_file: notes/plan.md"],
            diffs: [fixture.root + "/README.md"])
        expect(
            links.byMention["report.pdf"]?.path == fixture.root + "/out/report.pdf",
            "a bare name nobody placed is found among the files the calls touched")
        expect(
            links.files.map(\.name) == ["report.pdf", "README.md", "plan.md"],
            "written files follow what the reply named, got \(links.files.map(\.name))")
    }

    static func runnableThingsAreOnlyRevealed(_ fixture: Fixture) {
        let links = fixture.resolve(
            "Run `render.sh`, `deploy.command`, `tool` or `build/Tool.app`; read `README.md`.",
            directory: fixture.root)
        expect(links.byMention["render.sh"]?.kind == .executable, "a script is revealed, not run")
        expect(links.byMention["deploy.command"]?.kind == .executable, "a .command is revealed")
        expect(links.byMention["build/Tool.app"]?.kind == .package, "an app is revealed")
        expect(links.byMention["build/Tool.app"]?.opens == false, "and never opened")
        expect(links.byMention["README.md"]?.opens == true, "a document opens")
        let tool = ChatFileItem(path: fixture.root + "/tool", kind: ChatFileOpenPolicy.kind(
            of: fixture.root + "/tool", ChatFileStat(isExecutable: true)))
        expect(tool.kind == .executable, "an executable with no extension is revealed")
        let page = ChatFileItem(path: "/x/a.html", kind: .document)
        expect(ChatFileOpenPolicy.opens(page, defaultApp: "com.apple.Safari"), "a page opens in its browser")
        expect(!ChatFileOpenPolicy.opens(page, defaultApp: "com.apple.Terminal"), "never in a terminal")
        expect(!ChatFileOpenPolicy.opens(page, defaultApp: nil), "nor when no app claims it")
        expect(
            ChatFileOpenPolicy.opens(ChatFileItem(path: "/x", kind: .folder), defaultApp: nil),
            "a folder opens in Finder")
    }

    static func theStripIsDedupedAndCapped(_ fixture: Fixture) {
        let names = (1...9).map { "f\($0).md" }
        for name in names { FileManager.default.createFile(atPath: "\(fixture.root)/\(name)", contents: nil) }
        let reply = names.map { "`\($0)`" }.joined(separator: ", ") + " and again `f1.md`, `./f1.md`."
        let links = fixture.resolve(reply, directory: fixture.root, diffs: ["f2.md"])
        expect(links.files.count == 9, "one chip per file however it was written, got \(links.files.count)")
        let collapsed = ChatFileLinks.strip(links.files, expanded: false)
        expect(
            collapsed.shown.count == ChatFileLinks.stripLimit - 1 && collapsed.hidden == 4,
            "past the limit the last slot is +N, got \(collapsed.shown.count) +\(collapsed.hidden)")
        expect(ChatFileLinks.strip(links.files, expanded: true).hidden == 0, "expanded shows them all")
        let few = Array(links.files.prefix(ChatFileLinks.stripLimit))
        expect(ChatFileLinks.strip(few, expanded: false).hidden == 0, "a full row needs no +N")
    }

    static func eachPathIsLookedUpOnce(_ fixture: Fixture) {
        var lookups: [String] = []
        let reply = "`card-1-ada.png` in `posts/gpu-unlock-ada/assets/`, `card-1-ada.png` again, `nope.png`."
        _ = ChatFileResolver.resolve(
            ChatFileRequest(
                reply: reply, directory: fixture.root, home: fixture.home, toolTitles: [], diffPaths: []),
            stat: { path in
                lookups.append(path)
                return fixture.stat(path)
            })
        expect(lookups.count == Set(lookups).count, "no path is looked up twice, got \(lookups)")
        expect(lookups.count <= 4, "a short reply costs a few lookups, got \(lookups.count)")
    }
}
