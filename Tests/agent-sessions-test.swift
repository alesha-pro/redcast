import Foundation
import SQLite3

@main
@MainActor
struct AgentSessionsTests {
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

    static let fixtures = URL(filePath: "Tests/agent-sessions-fixtures", directoryHint: .isDirectory)
    static let scratch = FileManager.default.temporaryDirectory
        .appending(path: "agent-sessions-test-\(UUID().uuidString)", directoryHint: .isDirectory)

    static let s1 = "11111111-1111-4111-8111-111111111111"
    static let s2 = "22222222-2222-4222-8222-222222222222"
    static let s3 = "33333333-3333-4333-8333-333333333333"
    static let s4 = "44444444-4444-4444-8444-444444444444"
    static let s5 = "55555555-5555-4555-8555-555555555555"
    static let firstPrompt = "fix the redirect after login when the session expires — проверь"

    static func main() async {
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        lineFilter()
        headReader()
        tailReader()
        titles()
        rescanPolicy()
        await scannerOverFixtures()
        previews()
        codexReader()
        ranking()
        resumeCommands()
        hookFileFormat()
        hookCommandExecuted()
        deepLinks()
        activityPolicy()
        liveListing()
        await transcriptSearch()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Helpers

    static func fixture(_ path: String) -> Data {
        (try? Data(contentsOf: fixtures.appending(path: path))) ?? Data()
    }

    static func text(_ path: String) -> String {
        String(bytes: fixture(path), encoding: .utf8) ?? ""
    }

    static func claude(_ session: String, in folder: String = "-Users-me-dev-app") -> Data {
        fixture("claude/\(folder)/\(session).jsonl")
    }

    static func userLine(_ content: Any, extra: [String: Any] = [:]) -> [String: Any] {
        var line: [String: Any] = [
            "type": "user", "message": ["role": "user", "content": content], "origin": ["kind": "human"]
        ]
        line.merge(extra) { _, new in new }
        return line
    }

    static func head(of data: Data, chunk: Int) -> ClaudeTranscriptDecoder.HeadFacts {
        var reader = ClaudeTranscriptDecoder.HeadReader()
        var start = 0
        while start < data.count {
            let end = min(start + chunk, data.count)
            if reader.consume(data.subdata(in: start..<end)) { break }
            start = end
        }
        return reader.finish()
    }

    static func session(
        _ source: AgentSource, _ id: String, title: String, folder: String? = nil, first: String = "",
        updated: Double = 0, host: AgentSessionHost = .terminal, archived: Bool = false
    ) -> AgentSession {
        AgentSession(
            source: source, sessionID: id, title: title, titleOrigin: .named, firstPrompt: first,
            directory: folder, createdAt: Date(timeIntervalSince1970: updated),
            updatedAt: Date(timeIntervalSince1970: updated), host: host, isArchived: archived)
    }

    // MARK: - 1. Line filter

    static func lineFilter() {
        let machine = [
            "<command-name>/clear</command-name>", "<command-message>clear</command-message>",
            "<local-command-stdout>ok</local-command-stdout>", "<bash-input>ls</bash-input>",
            "<bash-stdout>a</bash-stdout>", "<system-reminder>x</system-reminder>",
            "Caveat: The messages below were generated", "[Request interrupted by user]"
        ]
        for text in machine {
            expect(ClaudeTranscriptDecoder.humanPrompt(in: userLine(text)) == nil, "not a prompt: \(text)")
        }
        expect(ClaudeTranscriptDecoder.humanPrompt(in: userLine("fix it")) == "fix it", "a string prompt")
        expect(
            ClaudeTranscriptDecoder.humanPrompt(in: userLine([["type": "text", "text": "fix it"]])) == "fix it",
            "a text-block prompt")
        let image: [[String: Any]] = [
            ["type": "image", "source": ["type": "base64", "data": "AAAA"]], ["type": "text", "text": "what is this"]
        ]
        expect(ClaudeTranscriptDecoder.humanPrompt(in: userLine(image)) == "what is this", "an image+text prompt")
        let toolResult: [[String: Any]] = [["tool_use_id": "t1", "type": "tool_result", "content": "x"]]
        expect(ClaudeTranscriptDecoder.humanPrompt(in: userLine(toolResult)) == nil, "tool output is no prompt")
        for flag in ["isMeta", "isCompactSummary", "isSidechain", "isVisibleInTranscriptOnly"] {
            expect(
                ClaudeTranscriptDecoder.humanPrompt(in: userLine("hi", extra: [flag: true])) == nil,
                "\(flag) is no prompt")
        }
        expect(
            ClaudeTranscriptDecoder.humanPrompt(in: userLine("hi", extra: ["origin": ["kind": "task-notification"]]))
                == nil, "a task notification is no prompt")
        expect(
            ClaudeTranscriptDecoder.humanPrompt(in: userLine("hi", extra: ["toolUseResult": ["a": 1]])) == nil,
            "a toolUseResult line is no prompt")
        expect(
            ClaudeTranscriptDecoder.humanPrompt(in: userLine("a\n\n   b\tc")) == "a b c", "whitespace collapses")
        expect(
            ClaudeTranscriptDecoder.humanPrompt(in: userLine(String(repeating: "x", count: 400)))?.count == 300,
            "a prompt is cut to 300 characters")

        func kind(_ text: String) -> ClaudeTranscriptDecoder.LineKind {
            ClaudeTranscriptDecoder.lineKind(of: Data(text.utf8))
        }
        expect(
            kind(#"{"type":"custom-title","customTitle":"x","sessionId":"s"}"#) == .meta("custom-title"),
            "a custom-title line is meta")
        let lines = ClaudeTranscriptDecoder.lines(of: claude(s1), startsMidLine: false)
        expect(ClaudeTranscriptDecoder.lineKind(of: lines[2]) == .conversation(user: true), "a prompt line")
        expect(ClaudeTranscriptDecoder.lineKind(of: lines[4]) == .conversation(user: false), "an assistant line")
        expect(ClaudeTranscriptDecoder.lineKind(of: lines[6]) == .toolOutput, "a tool_result line")
        expect(ClaudeTranscriptDecoder.lineKind(of: lines[1]) == .other, "a system line is skipped undecoded")
        let longReply =
            #"{"parentUuid":"u1","isSidechain":false,"message":{"model":"m","id":"msg","type":"message","#
            + #""role":"assistant","content":[{"type":"text","text":""# + String(repeating: "r", count: 900)
            + #""}]},"type":"assistant","uuid":"a"}"#
        expect(kind(longReply) == .conversation(user: false), "an assistant line whose type is past 512 bytes")
        let cyrillic = #"{"type":"custom-title","customTitle":""# + String(repeating: "ж", count: 400) + #""}"#
        expect(kind(cyrillic) == .meta("custom-title"), "a 512-byte cut inside a scalar is harmless")
        let cyrillicUser =
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p","type":"user","message":{"role":"user","#
            + #""content":""# + String(repeating: "ж", count: 400) + #""}}"#
        expect(kind(cyrillicUser) == .conversation(user: true), "a user line cut mid-scalar")
        expect(
            kind(#"{"parentUuid":null,"isSidechain":false,"attachment":{"kind":"file"},"type":"attachment"}"#)
                == .other, "an attachment line is skipped")
        expect(
            kind(#"{"type":"user","message":{"role":"user","content":"hi"}}"#) == .conversation(user: true),
            "a turn that leads with its type is still a turn")
    }

    // MARK: - 2. Head reader

    static func headReader() {
        let data = claude(s1)
        let whole = head(of: data, chunk: data.count)
        expect(whole.cwd == "/Users/me/dev/app", "cwd from the first conversation line")
        expect(whole.sessionID == s1, "session id")
        expect(whole.branch == "main" && whole.entrypoint == "cli", "branch and entrypoint")
        expect(whole.firstPrompt == firstPrompt, "first prompt, got \(whole.firstPrompt ?? "nil")")
        expect(whole.customTitle == "Early name", "a title at the head is kept")
        expect(whole.isComplete, "complete once cwd and prompt are known")
        expect(head(of: data, chunk: 7) == whole, "chunks split mid-line and mid-scalar read the same")
        expect(head(of: data, chunk: 1) == whole, "one byte at a time reads the same")

        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 10, 22)
        (components.hour, components.minute, components.second, components.nanosecond) = (14, 9, 26, 947_000_000)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let expected = utc.date(from: components)!
        expect(
            abs((whole.createdAt ?? .distantPast).timeIntervalSince(expected)) < 0.001,
            "createdAt parses 2026-10-22T14:09:26.947Z")

        let giant = try? JSONSerialization.data(withJSONObject: userLine(String(repeating: "g", count: 300_000)))
        var withGiant = giant ?? Data()
        withGiant.append(0x0A)
        withGiant.append(data)
        var reader = ClaudeTranscriptDecoder.HeadReader()
        var start = 0
        while start < withGiant.count {
            let end = min(start + 16_384, withGiant.count)
            if reader.consume(withGiant.subdata(in: start..<end)) { break }
            start = end
        }
        let afterGiant = reader.finish()
        expect(reader.largestCarry <= ClaudeTranscriptDecoder.lineCap, "a 300 KB line is never buffered")
        expect(afterGiant.firstPrompt == firstPrompt, "the prompt after a skipped giant line is found")

        let filler = Data(
            String(
                repeating: #"{"parentUuid":null,"isSidechain":false,"attachment":{"kind":"x"},"type":"attachment"}"#
                    + "\n", count: 8_000
            ).utf8)
        var capped = ClaudeTranscriptDecoder.HeadReader()
        var done = false
        var offset = 0
        while offset < filler.count, !done {
            let end = min(offset + 16_384, filler.count)
            done = capped.consume(filler.subdata(in: offset..<end))
            offset = end
        }
        expect(done && capped.consumed >= ClaudeTranscriptDecoder.headCap, "the head cap ends the read")
        expect(!capped.finish().isComplete, "a capped head is incomplete")
    }

    // MARK: - 3. Tail reader

    static func tailReader() {
        let tail1 = ClaudeTranscriptDecoder.tail(claude(s1), startsMidLine: false)
        expect(tail1.customTitle == "Login redirect fix", "the last custom-title wins")
        expect(tail1.aiTitle == "Fix login redirect", "ai-title is read too")
        expect(tail1.lastPrompt == "now add a test for it", "last-prompt")
        let head1 = head(of: claude(s1), chunk: 4_096)
        expect(
            ClaudeTranscriptDecoder.title(head: head1, tail: tail1) == ("Login redirect fix", .named),
            "a custom title beats an earlier one and an ai-title")

        let data4 = claude(s4, in: "-Users-me-dev-api")
        let tail4 = ClaudeTranscriptDecoder.tail(data4, startsMidLine: false)
        let head4 = head(of: data4, chunk: 4_096)
        expect(tail4.summary == "API pagination rework", "a legacy summary")
        expect(
            ClaudeTranscriptDecoder.title(head: head4, tail: tail4) == ("API pagination rework", .generated),
            "a summary titles the session")
        let item = ClaudeListingItem(path: "-Users-me-dev-api/\(s4).jsonl", size: Int64(data4.count), modified: 1)
        let entry = ClaudeIndexEntry(item: item, head: head4, tail: tail4)
        expect(entry.cwd == "/Users/me/dev/api", "relocatedCwd wins for the resume folder")
        expect(entry.branch == "feature/pages", "branch from the head")

        let partial = Data(
            (#"tle","customTitle":"Broken"}"# + "\n" + #"{"type":"ai-title","aiTitle":"Kept","sessionId":"s"}"#
                + "\n").utf8)
        let midLine = ClaudeTranscriptDecoder.tail(partial, startsMidLine: true)
        expect(midLine.customTitle == nil && midLine.aiTitle == "Kept", "startsMidLine drops the partial line")

        let tail2 = ClaudeTranscriptDecoder.tail(claude(s2), startsMidLine: false)
        expect(!tail2.hasTitle, "an untitled tail")
        expect(tail2.lastPrompt == "and update the docs", "the last human prompt stands in for last-prompt")
        expect(ClaudeTranscriptDecoder.needsWideTail(tail2, fileSize: 100_000), "a wide window is asked for")
        expect(!ClaudeTranscriptDecoder.needsWideTail(tail2, fileSize: 4_000), "not for a file the window held")
    }

    // MARK: - 4. Titles

    static func titles() {
        typealias Head = ClaudeTranscriptDecoder.HeadFacts
        typealias Tail = ClaudeTranscriptDecoder.TailFacts
        var head = Head()
        head.customTitle = "Head name"
        var tail = Tail()
        tail.aiTitle = "Generated"
        expect(ClaudeTranscriptDecoder.title(head: head, tail: tail) == ("Head name", .named), "a name anywhere")
        tail.customTitle = "Tail name"
        expect(ClaudeTranscriptDecoder.title(head: head, tail: tail) == ("Tail name", .named), "the tail's name")
        var generated = Head()
        generated.aiTitle = "Head ai"
        var summary = Tail()
        summary.summary = "Old summary"
        expect(
            ClaudeTranscriptDecoder.title(head: generated, tail: summary) == ("Head ai", .generated),
            "ai-title before a legacy summary")
        var prompt = Head()
        prompt.firstPrompt =
            "please rework the onboarding flow so that returning users skip the welcome screen entirely and land"
        let (cut, origin) = ClaudeTranscriptDecoder.title(head: prompt, tail: Tail())
        expect(origin == .prompt && cut.count <= 80 && cut.hasSuffix("…"), "a long prompt is cut, got \(cut)")
        expect(cut.hasSuffix(" welcome…"), "at a word boundary, got \(cut)")
        expect(ClaudeTranscriptDecoder.title(head: Head(), tail: Tail()) == ("", .untitled), "untitled")

        expect(
            CodexStateReader.title(name: "Renamed", title: "t", firstMessage: "f", preview: "p")
                == ("Renamed", .named), "a Codex name")
        expect(
            CodexStateReader.title(name: "", title: "Generated title", firstMessage: "do it", preview: "do it")
                == ("Generated title", .generated), "a Codex title unlike the first message")
        expect(
            CodexStateReader.title(name: "", title: "line one", firstMessage: "line one", preview: "line one\nline two")
                == ("line one", .prompt), "the preview's first line")
        expect(
            CodexStateReader.title(name: "", title: "", firstMessage: "", preview: "") == ("", .untitled),
            "untitled Codex thread")
    }

    // MARK: - 5. Rescan policy

    static func rescanPolicy() {
        let item = ClaudeListingItem(path: "p/a.jsonl", size: 100, modified: 10)
        var entry = ClaudeIndexEntry(item: item, head: .init(), tail: .init())
        entry.headDone = true
        func step(_ size: Int64, _ modified: Double, headDone: Bool = true) -> ClaudeRescanPolicy.Step {
            var cached = entry
            cached.headDone = headDone
            return ClaudeRescanPolicy.step(
                for: ClaudeListingItem(path: item.path, size: size, modified: modified), cached: cached)
        }
        expect(ClaudeRescanPolicy.step(for: item, cached: nil) == .full, "new → full")
        expect(step(100, 10) == .reuse, "same size and mtime → reuse")
        expect(step(150, 11) == .tail, "grown with its head done → tail")
        expect(step(50, 11) == .full, "shrunk → full")
        expect(step(150, 11, headDone: false) == .full, "grown without its head → full")
        let plan = ClaudeRescanPolicy.plan(
            cached: ["p/a.jsonl": entry, "p/gone.jsonl": entry],
            listing: [item, ClaudeListingItem(path: "p/b.jsonl", size: 1, modified: 20)])
        expect(plan.dropped == ["p/gone.jsonl"], "missing → dropped")
        expect(plan.steps.map(\.0.path) == ["p/b.jsonl", "p/a.jsonl"], "newest first")

        let file = ClaudeIndexFile(projectsRoot: "/Users/me/.claude/projects", entries: [entry])
        let data = file.encoded()
        expect(
            ClaudeIndexFile.decode(data, projectsRoot: "/Users/me/.claude/projects")?.entries == [entry],
            "the cache round-trips")
        expect(ClaudeIndexFile.decode(data, projectsRoot: "/elsewhere") == nil, "another root rebuilds")
        var other = file
        other.version = 2
        expect(
            ClaudeIndexFile.decode(other.encoded(), projectsRoot: "/Users/me/.claude/projects") == nil,
            "another version rebuilds")
        expect(ClaudeRescanPolicy.session(from: entry, root: "/r") == nil, "no title and no prompt: dropped")
    }

    static func scannerOverFixtures() async {
        let root = scratch.appending(path: "claude", directoryHint: .isDirectory)
        try? FileManager.default.copyItem(at: fixtures.appending(path: "claude"), to: root)
        let listing = await AgentSessionsScanner.listClaude(root: root)
        expect(listing.count == 5, "five top-level transcripts, got \(listing.count)")
        expect(!listing.contains { $0.path.contains("subagents") }, "a subagent transcript is never listed")
        let plan = ClaudeRescanPolicy.plan(cached: [:], listing: listing)
        expect(plan.steps.allSatisfy { $0.1 == .full }, "a first scan reads everything")
        let entries = await AgentSessionsScanner.scan(plan.steps, cached: [:], root: root)
        let sessions = entries.compactMap { ClaudeRescanPolicy.session(from: $0, root: root.path) }
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })
        expect(Set(byID.keys) == [s1, s2, s3, s4], "the empty session is dropped, got \(byID.keys.sorted())")
        expect(byID[s1]?.title == "Login redirect fix" && byID[s1]?.lastPrompt == "now add a test for it", "s1")
        expect(byID[s2]?.title == "rename the api client to HttpClient", "machine lines never title a session")
        expect(byID[s2]?.host == .claudeApp, "claude-desktop is the Claude app")
        expect(byID[s3]?.isAutomated == true, "sdk-cli is automated")
        expect(byID[s4]?.directory == "/Users/me/dev/api", "a relocated session resumes where it moved")

        let cacheURL = scratch.appending(path: "cache/claude-index.json")
        await AgentSessionsScanner.saveCache(
            ClaudeIndexFile(projectsRoot: root.path, entries: entries), to: cacheURL)
        let mode = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.posixPermissions] as? Int
        expect(mode == 0o600, "the cache is private")
        let loaded = await AgentSessionsScanner.loadCache(cacheURL, root: root.path)
        let cached = Dictionary(uniqueKeysWithValues: (loaded?.entries ?? []).map { ($0.path, $0) })
        expect(cached.count == 5, "the cache reloads")
        let again = ClaudeRescanPolicy.plan(cached: cached, listing: await AgentSessionsScanner.listClaude(root: root))
        expect(again.steps.allSatisfy { $0.1 == .reuse }, "an unchanged tree is all reuse")

        let grown = root.appending(path: "-Users-me-dev-app/\(s1).jsonl")
        let handle = try? FileHandle(forWritingTo: grown)
        _ = try? handle?.seekToEnd()
        try? handle?.write(
            contentsOf: Data((#"{"type":"last-prompt","lastPrompt":"and ship it","sessionId":"\#(s1)"}"# + "\n").utf8))
        try? handle?.close()
        let later = ClaudeRescanPolicy.plan(cached: cached, listing: await AgentSessionsScanner.listClaude(root: root))
        let step = later.steps.first { $0.0.path.hasSuffix(s1 + ".jsonl") }
        expect(step?.1 == .tail, "a grown file reads only its tail")
        let updated = await AgentSessionsScanner.scan(step.map { [$0] } ?? [], cached: cached, root: root)
        expect(updated.first?.last == "and ship it", "the tail brings the new last prompt")
        expect(updated.first?.title == "Login redirect fix", "and keeps the name")
    }

    static func previews() {
        let turns = ClaudeTranscriptDecoder.previewTurns(claude(s1), startsMidLine: false, limit: 8)
        expect(turns.map(\.role) == [.user, .assistant, .user, .assistant], "turns alternate, got \(turns.count)")
        expect(turns.first?.text == firstPrompt, "the prompt in full")
        expect(
            turns[safe: 1]?.text.contains("I will look at the login handler.") == true
                && turns[safe: 1]?.text.contains("Fixed:") == true,
            "tool output does not split a reply")
        expect(!(turns[safe: 1]?.text.contains("Looking at the handler") ?? true), "thinking is not shown")
        expect(
            ClaudeTranscriptDecoder.previewTurns(claude(s1), startsMidLine: false, limit: 2).map(\.text)
                == ["now add a test for it", "Added a test."], "the last N")
        let compacted = ClaudeTranscriptDecoder.previewTurns(claude(s2), startsMidLine: false, limit: 8)
        expect(
            compacted.filter { $0.role == .user }.map(\.text) == ["rename the api client to HttpClient", "and update the docs"],
            "compaction, notifications and interruptions are not turns")
        let long = String(repeating: "й", count: 5_000)
        expect(AgentSessionText.bounded(long).utf8.count <= AgentSessionText.turnLimit, "a turn is at most 4 KB")
        expect(AgentSessionText.bounded(long).hasSuffix("…"), "and says it was cut")
    }

    // MARK: - 6. Codex reader

    static func sqlite(_ url: URL, _ sql: String) {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            print("sqlite: \(error.map { String(cString: $0) } ?? "?")")
            sqlite3_free(error)
        }
    }

    static func codexID(_ number: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", number)
    }

    static func codexReader() {
        let state = scratch.appending(path: "state_5.sqlite")
        let columns = """
            id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL, source TEXT NOT NULL, model_provider TEXT, cwd TEXT NOT NULL,
            title TEXT NOT NULL, sandbox_policy TEXT, approval_mode TEXT, tokens_used INTEGER,
            has_user_event INTEGER, archived INTEGER NOT NULL DEFAULT 0, archived_at INTEGER, git_sha TEXT,
            git_branch TEXT, git_origin_url TEXT, cli_version TEXT, first_user_message TEXT NOT NULL DEFAULT '',
            agent_nickname TEXT, agent_role TEXT, memory_mode TEXT, model TEXT, reasoning_effort TEXT,
            agent_path TEXT, created_at_ms INTEGER, updated_at_ms INTEGER, thread_source TEXT,
            preview TEXT NOT NULL DEFAULT '', recency_at INTEGER, recency_at_ms INTEGER, history_mode TEXT,
            name TEXT, is_pinned INTEGER, project_id TEXT, originator TEXT, future_column TEXT
            """
        func row(
            _ number: Int, source: String = "cli", title: String = "add a token bucket",
            first: String = "add a token bucket", preview: String = "add a token bucket", archived: Int = 0,
            threadSource: String = "user", originator: String = "codex-tui", name: String? = nil
        ) -> String {
            let quotedName = name.map { "'\($0)'" } ?? "NULL"
            return """
                INSERT INTO threads (id, rollout_path, created_at, updated_at, source, cwd, title, archived,
                  git_branch, first_user_message, created_at_ms, updated_at_ms, thread_source, preview, name,
                  originator, future_column)
                VALUES ('\(codexID(number))', '/tmp/rollout-\(number).jsonl', \(number), \(1000 + number),
                  '\(source)', '/Users/me/dev/api', '\(title)', \(archived), 'main', '\(first)', \(number * 1000),
                  \((1000 + number) * 1000), '\(threadSource)', '\(preview)', \(quotedName), '\(originator)', 'x');
                """
        }
        let guardian = #"{"subagent":{"other":"guardian"}}"#
        let spawn = #"{"subagent":{"thread_spawn":{"parent_thread_id":"x"}}}"#
        sqlite(
            state,
            "CREATE TABLE threads (\(columns));"
                + row(1) + row(2, archived: 1) + row(3, source: guardian) + row(4, source: spawn)
                + row(5, source: "exec") + row(6, source: "vscode", originator: "tinycast") + row(7, preview: "")
                + row(8, source: "vscode", originator: "Codex Desktop", name: "Release checklist")
                + row(9, source: "vscode", title: "Refactor parser", first: "please refactor the parser",
                      preview: "please refactor the parser", originator: "")
                + row(10, source: "vscode", threadSource: "guardian_review")
                + row(11, threadSource: "automation"))
        let visible = (try? CodexStateReader.threads(database: state, includeArchived: false)) ?? []
        expect(
            visible.map(\.sessionID) == [11, 9, 8, 5, 1].map(codexID),
            "visible, non-subagent threads newest first, got \(visible.map(\.sessionID))")
        let all = (try? CodexStateReader.threads(database: state, includeArchived: true)) ?? []
        expect(all.contains { $0.sessionID == codexID(2) && $0.isArchived }, "archived only with the flag")
        let hosts = Dictionary(uniqueKeysWithValues: visible.map { ($0.sessionID, $0.host) })
        expect(hosts[codexID(1)] == .terminal, "cli is a terminal")
        expect(hosts[codexID(5)] == .automated && hosts[codexID(11)] == .automated, "exec and automation")
        expect(hosts[codexID(8)] == .codexApp, "vscode from Codex Desktop is the app")
        expect(hosts[codexID(9)] == .editor, "other vscode is an editor")
        let titles = Dictionary(uniqueKeysWithValues: visible.map { ($0.sessionID, ($0.title, $0.titleOrigin)) })
        expect(titles[codexID(8)]! == ("Release checklist", .named), "a renamed thread")
        expect(titles[codexID(9)]! == ("Refactor parser", .generated), "a generated title")
        expect(titles[codexID(1)]! == ("add a token bucket", .prompt), "a title that is the first message")
        expect(
            (try? CodexStateReader.thread(database: state, id: codexID(8)))??.title == "Release checklist",
            "one thread by id")

        let older = scratch.appending(path: "state-older.sqlite")
        sqlite(
            older,
            """
            CREATE TABLE threads (id TEXT, rollout_path TEXT, created_at INTEGER, updated_at INTEGER,
              source TEXT, cwd TEXT, title TEXT, first_user_message TEXT, preview TEXT, archived INTEGER);
            INSERT INTO threads VALUES ('\(codexID(1))', '/tmp/r', 1, 2, 'cli', '/Users/me', 'hello there',
              'hello there', 'hello there', 0);
            """)
        let read = (try? CodexStateReader.threads(database: older, includeArchived: false)) ?? []
        expect(read.count == 1 && read.first?.updatedAt == Date(timeIntervalSince1970: 2), "an older schema reads")

        let broken = scratch.appending(path: "state-broken.sqlite")
        sqlite(broken, "CREATE TABLE threads (id TEXT, rollout_path TEXT, created_at INTEGER, updated_at INTEGER);")
        do {
            _ = try CodexStateReader.threads(database: broken, includeArchived: false)
            expect(false, "a database without cwd fails")
        } catch {
            expect(error == .schema("cwd"), "a database without cwd fails with .schema, got \(error)")
        }
        do {
            _ = try CodexStateReader.threads(database: scratch.appending(path: "none.sqlite"), includeArchived: false)
            expect(false, "a missing database fails")
        } catch {
            expect(error == .missing, "a missing database is .missing")
        }

        let history = scratch.appending(path: "thread_history_1.sqlite")
        func item(_ ordinal: Int, _ type: String, _ json: String) -> String {
            """
            INSERT INTO thread_items VALUES ('\(codexID(1))', 't', 'i\(ordinal)', \(ordinal), \(ordinal * 1000),
              '\(json)', '\(type)');
            """
        }
        sqlite(
            history,
            """
            CREATE TABLE thread_items (thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, item_id TEXT NOT NULL,
              rollout_ordinal INTEGER NOT NULL, created_at_ms INTEGER NOT NULL, item_json TEXT NOT NULL,
              item_type TEXT NOT NULL DEFAULT '', PRIMARY KEY (thread_id, turn_id, item_id));
            """
                + item(1, "userMessage", #"{"type":"userMessage","content":[{"type":"text","text":"first"}]}"#)
                + item(2, "agentMessage", #"{"type":"agentMessage","text":"one","phase":"final_answer"}"#)
                + item(3, "reasoning", #"{"type":"reasoning","text":"hidden"}"#)
                + item(
                    4, "userMessage",
                    #"{"type":"userMessage","content":[{"type":"text","text":"<environment_context>x</environment_context>"}]}"#)
                + item(5, "userMessage", #"{"type":"userMessage","content":[{"type":"text","text":"second"}]}"#)
                + item(6, "agentMessage", #"{"type":"agentMessage","text":"two"}"#))
        let turns = (try? CodexStateReader.historyTurns(database: history, threadID: codexID(1), limit: 4)) ?? []
        expect(turns.map(\.text) == ["one", "second", "two"], "the last projected items in order, got \(turns.map(\.text))")
        expect(turns.map(\.role) == [.assistant, .user, .assistant], "with their roles")
        expect(
            (try? CodexStateReader.historyMatch(database: history, threadID: codexID(1), needle: "SECOND")) == "second",
            "a projected message is searched case-insensitively")

        let rollout = CodexStateReader.rolloutTurns(fixture("codex/rollout-sample.jsonl"), startsMidLine: false, limit: 8)
        expect(
            rollout.map(\.text)
                == ["add a token bucket rate limiter", "Added RateLimiter.", "make the burst configurable",
                    "Done: burst is a parameter."], "rollout turns skip developer and context text")
    }

    // MARK: - 7. Ranking

    static func ranking() {
        let login = session(
            .claude, "a", title: "Login redirect fix", folder: "/Users/me/dev/app",
            first: "fix the redirect after login", updated: 10)
        let limiter = session(
            .codex, "b", title: "Rate limiter", folder: "/Users/me/dev/api",
            first: "please fix the login page styling", updated: 20)
        let both = session(.claude, "c", title: "Fix redirect", folder: "/Users/me/dev/api", updated: 5)
        let russian = session(.tinycast, "d", title: "Проверка кэша", updated: 1)
        let cafe = session(.tinycast, "e", title: "Café menu", updated: 2)
        let automated = session(.claude, "f", title: "Nightly job", updated: 30, host: .automated)
        let archived = session(.codex, "g", title: "Old thread", updated: 40, archived: true)
        let all = [login, limiter, both, russian, cafe, automated, archived]
        let entries = all.map { ($0, AgentSessionSearchKeys($0)) }
        func rank(_ query: String, filter: AgentSessionFilter = .init(), live: [String: AgentLiveEntry] = [:])
            -> [String]
        {
            AgentSessionQuery.rank(entries, query: query, filter: filter, live: live).map(\.sessionID)
        }
        expect(rank("login").first == "a", "a title prefix beats a prompt substring, got \(rank("login"))")
        expect(rank("login").contains("b"), "the prompt still matches")
        expect(Array(rank("api").prefix(2)).sorted() == ["b", "c"], "a folder query ranks that folder's sessions")
        expect(rank("thdaft").isEmpty, "a prompt never matches by subsequence, got \(rank("thdaft"))")
        expect(rank("redirect api") == ["c"], "every word must land somewhere, got \(rank("redirect api"))")
        expect(rank("проверка") == ["d"], "Cyrillic folds")
        expect(rank("cafe") == ["e"], "diacritics fold")
        expect(rank("", filter: AgentSessionFilter(source: .codex)) == ["b"], "the source filter")
        expect(rank("").contains("f") == false, "automated runs are hidden by default")
        expect(rank("", filter: AgentSessionFilter(showsAutomated: true)).contains("f"), "and shown on request")
        expect(rank("").contains("g") == false, "archived threads are hidden by default")
        expect(rank("", filter: AgentSessionFilter(showsArchived: true)).contains("g"), "and shown on request")
        let live = [
            "claude:c": AgentLiveEntry(
                sessionID: "c", status: .working, pid: 1, backgroundID: nil, directory: nil),
            "tinycast:d": AgentLiveEntry(
                sessionID: "d", status: .waiting(reason: nil), pid: 2, backgroundID: nil, directory: nil)
        ]
        expect(Array(rank("", live: live).prefix(2)) == ["d", "c"], "live first, waiting before working")
        let many = (0..<400).map { session(.claude, "s\($0)", title: "Session \($0)", updated: Double($0)) }
        let manyEntries = many.map { ($0, AgentSessionSearchKeys($0)) }
        expect(
            AgentSessionQuery.rank(manyEntries, query: "", filter: .init(), live: [:]).count == 300
                && AgentSessionQuery.rank(manyEntries, query: "session", filter: .init(), live: [:]).count == 300,
            "at most 300 rows")
    }

    // MARK: - 8. Resume commands

    static func resumeCommands() {
        expect(AgentResumeCommand.isSafeID(s1), "a UUID is safe")
        for unsafe in ["a;b", "a b", "a'b", "a\"b", String(repeating: "a", count: 65), ""] {
            expect(!AgentResumeCommand.isSafeID(unsafe), "unsafe id \(unsafe.prefix(10))")
        }
        let app = session(.claude, s1, title: "t", folder: "/Users/me/dev/app")
        expect(
            AgentResumeCommand.command(for: app, action: .resume) == "cd '/Users/me/dev/app' && claude --resume \(s1)",
            "claude resume")
        expect(
            AgentResumeCommand.command(for: app, action: .fork)
                == "cd '/Users/me/dev/app' && claude --resume \(s1) --fork-session", "claude fork")
        let codex = session(.codex, codexID(1), title: "t", folder: "/Users/me/dev/api")
        expect(
            AgentResumeCommand.command(for: codex, action: .resume) == "cd '/Users/me/dev/api' && codex resume \(codexID(1))",
            "codex resume")
        expect(
            AgentResumeCommand.command(for: codex, action: .fork) == "cd '/Users/me/dev/api' && codex fork \(codexID(1))",
            "codex fork")
        expect(AgentResumeCommand.command(for: app, action: .attach(shortID: "bg7")) == "claude attach bg7", "attach")
        expect(AgentResumeCommand.command(for: session(.claude, "x;rm", title: "t"), action: .resume) == nil, "no command")
        expect(AgentResumeCommand.command(for: session(.tinycast, s1, title: "t"), action: .resume) == nil, "no CLI")

        let hostile = [
            "it's", "a\"b", "back\\slash", "$(touch /tmp/agent-sessions-pwned)", "`id`", "new\nline",
            "sp ace", "дев/папка"
        ]
        // A template compiles only against its app's dictionary, so one without the app is skipped.
        let scriptable = [AgentTerminal.terminal, .iTerm, .ghostty].filter { terminal in
            compiles(AgentResumeCommand.appleScript(for: terminal, command: "true", directory: "/tmp"))
        }
        expect(scriptable.contains(.terminal), "Terminal's templates compile on every Mac")
        for name in hostile {
            let quoted = AgentResumeCommand.shellQuoted(name)
            expect(shell("printf %s " + quoted) == name, "shell quoting round-trips \(name.debugDescription)")
            let folder = "/Users/me/" + name
            let hostileSession = session(.claude, s1, title: "t", folder: folder)
            let command = AgentResumeCommand.command(for: hostileSession, action: .resume) ?? ""
            expect(
                evaluated(AgentResumeCommand.appleScriptString(command)) == command,
                "an AppleScript literal round-trips \(name.debugDescription)")
            for terminal in scriptable {
                for line in [command, nil] {
                    let source = AgentResumeCommand.appleScript(for: terminal, command: line, directory: folder)
                    expect(compiles(source), "\(terminal) script compiles for \(name.debugDescription)")
                }
            }
        }
        expect(!FileManager.default.fileExists(atPath: "/tmp/agent-sessions-pwned"), "nothing was executed")
        for terminal in scriptable where terminal != .ghostty {
            expect(compiles(AgentResumeCommand.focusScript(for: terminal, tty: "ttys004")), "\(terminal) focus")
        }
        expect(AgentResumeCommand.focusScript(for: .terminal, tty: "ttys0\"; do") == nil, "a bad tty")
        expect(AgentResumeCommand.focusScript(for: .warp, tty: "ttys004") == nil, "Warp can't focus a tab")

        let body = AgentResumeCommand.script(command: "cd '/a' && claude --resume \(s1)")
        let lines = body.split(separator: "\n").map(String.init)
        expect(lines.first == "#!/bin/sh" && lines[safe: 1] == #"/bin/rm -f -- "$0""#, "the script deletes itself first")
        expect(lines[safe: 2] == "cd '/a' && exec claude --resume \(s1)", "then execs the agent")

        let url = AgentResumeCommand.folderURL(scheme: "warp", directory: "/Users/me/my dir/ж&x=1#y")
        expect(
            url?.absoluteString == "warp://action/new_tab?path=/Users/me/my%20dir/%D0%B6%26x%3D1%23y",
            "the Warp path is encoded, got \(url?.absoluteString ?? "nil")")
        expect(AgentTerminal.ghostty.launch(version: "1.2.3") == .folderURL(scheme: ""), "old Ghostty")
        expect(AgentTerminal.ghostty.launch(version: "1.3.1") == .appleScript, "Ghostty 1.3")
        expect(AgentTerminal.zap.launch(version: nil) == .shellScript, "Zap runs a script")

        let installed: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"]
        expect(
            AgentTerminalPolicy.choose(preferred: "iTerm", lastHostBundleID: nil, installed: installed) == .iTerm,
            "a preference wins")
        expect(
            AgentTerminalPolicy.choose(
                preferred: "warp", lastHostBundleID: "com.mitchellh.ghostty", installed: installed) == .ghostty,
            "an uninstalled preference falls back to the last host")
        expect(
            AgentTerminalPolicy.choose(preferred: "", lastHostBundleID: nil, installed: installed) == .terminal,
            "then Terminal")
    }

    static func shell(_ script: String) -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        let output = Pipe()
        process.standardOutput = output
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// `return <literal>` only: the value comes back, and nothing is sent to any app.
    static func evaluated(_ literal: String) -> String? {
        var error: NSDictionary?
        return NSAppleScript(source: "return " + literal)?.executeAndReturnError(&error).stringValue
    }

    static func compiles(_ source: String?) -> Bool {
        guard let source, let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        return script.compileAndReturnError(&error)
    }

    // MARK: - 9. Hook file format

    static let token = "0123456789abcdef0123456789abcdef"
    static let fork = "com.tinycast.app.fork"
    static let dev = "com.tinycast.app.dev"

    static func install(_ text: String?, _ target: AgentHookTarget = .claude, bundle: String = fork, token: String = token)
        -> AgentHookFileFormat.Change?
    {
        try? AgentHookFileFormat.install(into: text, target: target, bundleID: bundle, token: token)
    }

    static func remove(_ text: String, _ target: AgentHookTarget = .claude, bundle: String = fork)
        -> AgentHookFileFormat.Change?
    {
        try? AgentHookFileFormat.remove(from: text, target: target, bundleID: bundle)
    }

    static func hookFileFormat() {
        let plain = text("hooks/claude-settings-plain.json")
        let installed = install(plain)?.after
        expect(installed == text("hooks/claude-settings-plain.expected.json"), "install into a plain file")
        expect(
            installed?.hasPrefix(String(plain.dropLast(3))) == true,
            "the bytes before the inserted member are unchanged")
        expect(remove(installed ?? "")?.after == plain, "removal restores the original bytes")
        expect(install(installed)?.isEmpty == true, "reinstalling changes nothing")

        let other = text("hooks/claude-settings-other-hooks.json")
        let merged = install(other)?.after
        expect(merged == text("hooks/claude-settings-other-hooks.expected.json"), "another tool's hooks are kept")
        expect(merged?.hasSuffix("  \"model\": \"opus\",\n  \"cleanupPeriodDays\": 30.0\n}\n") == true, "the rest stays")
        expect(remove(merged ?? "")?.after == other, "removal leaves only theirs, byte for byte")
        expect(
            AgentHookFileFormat.state(of: merged, target: .claude, bundleID: fork, token: token) == .installed,
            "installed beside another tool's events, whatever their order")
        expect(install(other)?.removedLines.isEmpty == true, "an insertion removes no line")

        let empty = install("{}\n")
        expect(empty?.after?.hasPrefix("{\n  \"hooks\": {\n") == true, "into {}")
        expect(remove(empty?.after ?? "")?.after == "{}\n", "and back to {}")

        let crlf = "{\r\n    \"model\": \"opus\"\r\n}\r\n"
        let crlfInstalled = install(crlf)?.after ?? ""
        expect(
            crlfInstalled.contains("\"opus\",\r\n    \"hooks\": {\r\n        \"UserPromptSubmit\": [\r\n"),
            "a four-space CRLF file keeps its style")
        expect(remove(crlfInstalled)?.after == crlf, "and its removal restores it")

        let codex = install(nil, .codex)
        expect(codex?.before == nil && codex?.after == text("hooks/codex-hooks-new.expected.json"), "a new hooks.json")
        let codexRemoved = remove(codex?.after ?? "", .codex)
        expect(codexRemoved != nil && codexRemoved?.after == nil, "a hooks.json holding only ours is deleted")

        let outdated = install(plain, token: "ffffffffffffffffffffffffffffffff")?.after ?? ""
        let replaced = install(outdated)?.after ?? ""
        expect(replaced == installed, "an outdated template is replaced, not duplicated")
        expect(
            AgentHookFileFormat.state(of: outdated, target: .claude, bundleID: fork, token: token) == .outdated,
            "a stale token reads as outdated")

        let both = install(installed, bundle: dev)?.after ?? ""
        expect(
            AgentHookFileFormat.state(of: both, target: .claude, bundleID: fork, token: token) == .installed
                && AgentHookFileFormat.state(of: both, target: .claude, bundleID: dev, token: token) == .installed,
            "two channels coexist")
        let devOnly = remove(both)?.after ?? ""
        expect(
            AgentHookFileFormat.state(of: devOnly, target: .claude, bundleID: fork, token: token) == .absent
                && AgentHookFileFormat.state(of: devOnly, target: .claude, bundleID: dev, token: token) == .installed,
            "and remove independently")
        expect(remove(devOnly, bundle: dev)?.after == plain, "removing both restores the original")
        expect(remove(plain) == nil, "nothing of ours: nothing to remove")

        func failure(_ text: String?, _ target: AgentHookTarget = .claude) -> AgentHookFileFormat.Failure? {
            do {
                _ = try AgentHookFileFormat.install(into: text, target: target, bundleID: fork, token: token)
                return nil
            } catch {
                return error
            }
        }
        expect(failure("{\"disableAllHooks\": true}") == .allHooksDisabled, "disableAllHooks is refused")
        expect(failure("{\"disableAllHooks\": true}", .codex) == nil, "only for Claude")
        expect(failure("{ not json") == .notJSON, "invalid JSON")
        expect(failure("[1, 2]") == .notObject, "an array root")
        expect(failure("{\"hooks\": []}") == .hooksNotObject, "hooks must be an object")

        expect(AgentHookFileFormat.state(of: nil, target: .claude, bundleID: fork, token: token) == .absent, "absent")
        expect(AgentHookFileFormat.state(of: plain, target: .claude, bundleID: fork, token: token) == .absent, "none")
        expect(
            AgentHookFileFormat.state(of: installed, target: .claude, bundleID: fork, token: token) == .installed,
            "installed")
        expect(
            AgentHookFileFormat.state(of: installed, target: .claude, bundleID: fork, token: nil) == .outdated,
            "no token on record")
        if case .unreadable = AgentHookFileFormat.state(of: "{", target: .claude, bundleID: fork, token: token) {
            expect(true, "unreadable")
        } else {
            expect(false, "a broken file is unreadable")
        }

        let parsed = (try? JSONSerialization.jsonObject(with: Data((installed ?? "").utf8))) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: [[String: Any]]] ?? [:]
        expect(
            Set(hooks.keys) == ["UserPromptSubmit", "Notification", "Stop", "StopFailure", "SessionEnd"],
            "the Claude events")
        let notification = hooks["Notification"]?.first
        expect(
            notification?["matcher"] as? String
                == "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input",
            "the waiting matcher")
        let handler = (hooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.first
        expect(handler?["type"] as? String == "command" && handler?["async"] as? Bool == true, "async commands")
        expect(
            (handler?["command"] as? String)?.contains(AgentHookFileFormat.marker(bundleID: fork)) == true,
            "the marker finds it")
    }

    // MARK: - 10. Hook command, executed

    static func hookCommandExecuted() {
        let folder = scratch.appending(path: "shims", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let running = folder.appending(path: "running")
        let openLog = folder.appending(path: "open.log")
        let lsappinfo = folder.appending(path: "lsappinfo")
        let open = folder.appending(path: "open")
        try? """
            #!/bin/sh
            if [ -f '\(running.path)' ]; then echo 'ASN:0x0-0x1234:'; fi
            """.write(to: lsappinfo, atomically: true, encoding: .utf8)
        try? """
            #!/bin/sh
            for argument in "$@"; do printf '%s\\n' "$argument" >> '\(openLog.path)'; done
            """.write(to: open, atomically: true, encoding: .utf8)
        for shim in [lsappinfo, open] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        }
        var tools = AgentHookFileFormat.Tools.system
        tools.lsappinfo = lsappinfo.path
        tools.open = open.path
        let command = AgentHookFileFormat.command(
            target: .claude, event: .waiting, bundleID: fork, token: token, tools: tools)

        func run(_ payload: String) -> (status: Int32, opened: [String]) {
            try? FileManager.default.removeItem(at: openLog)
            let process = Process()
            process.executableURL = URL(filePath: "/bin/bash")
            process.arguments = ["-c", command]
            let input = Pipe()
            process.standardInput = input
            guard (try? process.run()) != nil else { return (-1, []) }
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            do {
                try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
            } catch {
                expect(false, "the agent side never sees EPIPE: \(error)")
            }
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            let log = (try? String(contentsOf: openLog, encoding: .utf8)) ?? ""
            return (process.terminationStatus, log.split(separator: "\n").map(String.init))
        }

        let compact =
            #"{"session_id":"\#(s1)","transcript_path":"/x","cwd":"/Users/me/dev/app","hook_event_name":"Notification","#
            + #""notification_type":"permission_prompt","message":"Claude needs your permission"}"#
        let quiet = run(compact)
        expect(quiet.status == 0 && quiet.opened.isEmpty, "with Tinycast not running nothing opens")

        FileManager.default.createFile(atPath: running.path, contents: Data())
        let pid = ProcessInfo.processInfo.processIdentifier
        let url =
            "tinycast://agent-sessions/event?v=1&k=\(token)&agent=claude&event=waiting&session=\(s1)"
            + "&kind=permission_prompt&pid=\(pid)"
        let loud = run(compact)
        expect(loud.status == 0 && loud.opened == ["-g", "-b", fork, url], "the event URL, got \(loud.opened)")

        let pretty = "{\n  \"notification_type\": \"permission_prompt\",\n  \"session_id\": \"\(s1)\"\n}\n"
        expect(run(pretty).opened.last == url, "pretty-printed JSON reads the same")

        let evil =
            #"{"session_id":"\#(s1)","last_assistant_message":"say \"session_id\": \"evil-evil-evil\" now"}"#
        expect(run(evil).opened.last?.contains("session=\(s1)&") == true, "a lookalike in text is ignored")

        let large = #"{"session_id":"\#(s1)","last_assistant_message":""# + String(repeating: "z", count: 200_000) + "\"}"
        let drained = run(large)
        expect(drained.status == 0 && drained.opened.last?.contains(s1) == true, "200 KB of stdin is drained")

        let system = AgentHookFileFormat.command(target: .codex, event: .finished, bundleID: fork, token: token)
        let bare = try? NSRegularExpression(pattern: #"(?<![/\w-])(head|cat|sed|lsappinfo|open)\b"#)
        let range = NSRange(system.startIndex..., in: system)
        expect(bare?.numberOfMatches(in: system, range: range) == 0, "every tool is called by absolute path")
        expect(system.contains("/usr/bin/open -g -b \(fork) \"tinycast://"), "the open call is absolute")
    }

    // MARK: - 11. Deep links

    static func deepLinks() {
        func url(_ text: String) -> URL { URL(string: text)! }
        expect(AgentDeepLink.claims(url("tinycast://agent-sessions/x")), "agent-sessions is claimed")
        expect(!AgentDeepLink.claims(url("tinycast://extensions/a/b")), "extensions are not")
        let base = "tinycast://agent-sessions/event?v=1&k=\(token)&agent=codex&event=finished&session=\(s1)"
        let full = base + "&kind=permission_prompt&pid=4242"
        expect(
            AgentDeepLink.parse(url(full), token: token)
                == .event(AgentEvent(agent: .codex, event: .finished, sessionID: s1, kind: "permission_prompt", pid: 4242)),
            "the full grammar")
        expect(AgentDeepLink.parse(url(base + "&kind=&pid="), token: token) != nil, "empty kind and pid")
        let wrongToken = base.replacingOccurrences(of: token, with: String(repeating: "0", count: 32))
        expect(AgentDeepLink.parse(url(wrongToken), token: token) == nil, "a wrong token")
        expect(AgentDeepLink.parse(url(full), token: nil) == nil, "no token on record")
        expect(
            AgentDeepLink.parse(url(full.replacingOccurrences(of: "k=\(token)&", with: "")), token: token) == nil,
            "a missing token")
        expect(AgentDeepLink.parse(url(full.replacingOccurrences(of: "v=1", with: "v=2")), token: token) == nil, "v=2")
        expect(
            AgentDeepLink.parse(url(full.replacingOccurrences(of: s1, with: "abc%24def12")), token: token) == nil,
            "a bad session charset")
        expect(
            AgentDeepLink.parse(url(full.replacingOccurrences(of: s1, with: String(repeating: "a", count: 70))), token: token)
                == nil, "a 70-character session")
        expect(AgentDeepLink.parse(url(full.replacingOccurrences(of: "4242", with: "-4")), token: token) == nil, "pid -4")
        expect(
            AgentDeepLink.parse(url(full.replacingOccurrences(of: "4242", with: "123456789")), token: token) == nil,
            "a huge pid")
        expect(
            AgentDeepLink.parse(url(full.replacingOccurrences(of: "finished", with: "exploded")), token: token) == nil,
            "an unknown event")
        expect(
            AgentDeepLink.parse(url(full.replacingOccurrences(of: "agent=codex", with: "agent=tinycast")), token: token)
                == nil, "an unknown agent")
        let long = String(repeating: "q", count: 300)
        expect(
            AgentDeepLink.parse(url("tinycast://agent-sessions/open?q=\(long)"), token: nil)
                == .open(query: String(repeating: "q", count: 200)), "open?q= caps at 200")
        expect(AgentDeepLink.parse(url("tinycast://agent-sessions/jump"), token: nil) == .jump, "jump")
        expect(AgentDeepLink.parse(url("tinycast://agent-sessions/other"), token: nil) == nil, "unknown path")
        expect(AgentDeepLink.constantTimeEqual("abc", "abc") && !AgentDeepLink.constantTimeEqual("abc", "abd"), "compare")
    }

    // MARK: - 12. Activity policy

    static func activityPolicy() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func event(_ kind: AgentHookEvent, _ id: String = s1) -> AgentEvent {
            AgentEvent(agent: .claude, event: kind, sessionID: id, kind: nil, pid: nil)
        }
        func resolved(_ id: String = s1, at offset: TimeInterval, automated: Bool = false, host: String? = nil)
            -> AgentActivity
        {
            AgentActivity(
                agent: .claude, sessionID: id, directory: "/Users/me/dev/app", hostBundleID: host,
                isAutomated: automated, updatedAt: start.addingTimeInterval(offset))
        }
        var items: [AgentActivity] = []
        for (offset, kind) in [(0.0, AgentHookEvent.working), (5, .waiting), (9, .finished)] {
            items = AgentActivityPolicy.apply(
                event(kind), resolved: resolved(at: offset), to: items, now: start.addingTimeInterval(offset))
        }
        expect(items.count == 1 && items.first?.status == .finished && items.first?.seen == false, "one session")
        let stale = AgentActivityPolicy.apply(
            event(.working), resolved: resolved(at: 1), to: items, now: start.addingTimeInterval(10))
        expect(stale.first?.status == .finished, "an older event never overwrites a newer one")

        var ended = AgentActivityPolicy.apply(
            event(.ended, "e"), resolved: resolved("e", at: 0), to: [], now: start)
        ended = AgentActivityPolicy.prune(ended, now: start.addingTimeInterval(599))
        expect(ended.count == 1, "ended lingers ten minutes")
        expect(AgentActivityPolicy.prune(ended, now: start.addingTimeInterval(601)).isEmpty, "then goes")
        expect(
            AgentActivityPolicy.prune(items, now: start.addingTimeInterval(12 * 3_600 + 10)).isEmpty,
            "anything goes after 12 h")
        var many: [AgentActivity] = []
        for index in 0..<40 {
            many = AgentActivityPolicy.apply(
                event(.working, "s\(index)"), resolved: resolved("s\(index)", at: Double(index)), to: many,
                now: start.addingTimeInterval(Double(index)))
        }
        expect(many.count == 32 && many.first?.sessionID == "s39", "capacity 32, oldest out first")

        let waitingOld = AgentActivity(
            agent: .claude, sessionID: "w1", status: .waiting(reason: nil), updatedAt: start)
        let waitingNew = AgentActivity(
            agent: .codex, sessionID: "w2", status: .waiting(reason: nil), updatedAt: start.addingTimeInterval(5))
        let finished = AgentActivity(agent: .claude, sessionID: "f", status: .finished, updatedAt: start.addingTimeInterval(9))
        var seen = finished
        seen.seen = true
        expect(AgentActivityPolicy.jumpTarget([waitingOld, finished, waitingNew])?.sessionID == "w2", "newest waiting")
        expect(AgentActivityPolicy.jumpTarget([finished])?.sessionID == "f", "unseen finished without waiting")
        expect(AgentActivityPolicy.jumpTarget([seen]) == nil, "nothing left to jump to")

        let done = AgentActivity(
            agent: .claude, sessionID: s1, status: .finished, hostBundleID: "com.apple.Terminal", updatedAt: start)
        func announce(
            _ activity: AgentActivity, previous: AgentActivity? = nil, front: String? = "com.apple.Safari",
            last: Date? = nil
        ) -> AgentActivityPolicy.Announcement? {
            AgentActivityPolicy.announcement(
                for: activity, previous: previous, frontmostBundleID: front, lastAnnounced: last, now: start)
        }
        expect(announce(done) == .init(tone: .success, kind: .finished), "a finished turn is announced")
        var automated = done
        automated.isAutomated = true
        expect(announce(automated) == nil, "not for an automated run")
        var desktop = done
        desktop.hostBundleID = "com.anthropic.claudefordesktop.helper"
        expect(announce(desktop) == nil, "not for a desktop app's own session")
        expect(announce(done, front: "com.apple.Terminal") == nil, "not when its host is in front")
        expect(announce(done, last: start.addingTimeInterval(-5)) == nil, "not twice within 10 s")
        expect(announce(done, previous: done) == nil, "not for an unchanged status")
        var working = done
        working.status = .working
        expect(announce(working) == nil, "working is never announced")
        var failed = done
        failed.status = .failed
        expect(announce(failed)?.tone == .danger, "a failure is red")
    }

    // MARK: - 13. Live listing

    static func liveListing() {
        let entries = ClaudeAgentsListing.decode(fixture("claude-agents.json"))
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.sessionID, $0) })
        expect(entries.count == 5, "an entry without sessionId is skipped, got \(entries.count)")
        expect(byID[s1]?.status == .waiting(reason: "permission prompt") && byID[s1]?.pid == 4242, "waiting")
        expect(byID[s4]?.status == .working, "busy is working")
        let background = byID["66666666-6666-4666-8666-666666666666"]
        expect(
            background?.status == .waiting(reason: "worker request") && background?.backgroundID == "bg7",
            "a blocked background session")
        expect(byID["77777777-7777-4777-8777-777777777777"]?.status == .idle, "an unknown status is idle")
        expect(byID["88888888-8888-4888-8888-888888888888"]?.status == .finished, "a done background session")
        expect(ClaudeAgentsListing.decode(Data("not json".utf8)).isEmpty, "garbage decodes to nothing")
    }

    // MARK: - Search inside transcripts

    static func transcriptSearch() async {
        let root = scratch.appending(path: "claude", directoryHint: .isDirectory)
        let listing = await AgentSessionsScanner.listClaude(root: root)
        let entries = await AgentSessionsScanner.scan(
            listing.map { ($0, ClaudeRescanPolicy.Step.full) }, cached: [:], root: root)
        let sessions = entries.compactMap { ClaudeRescanPolicy.session(from: $0, root: root.path) }
        func hits(_ query: String) async -> [AgentTranscriptSearch.Hit] {
            var found: [AgentTranscriptSearch.Hit] = []
            for await hit in AgentTranscriptSearch.run(
                query: query, sessions: sessions, codexHistory: scratch.appending(path: "none.sqlite"),
                progress: { _, _ in })
            {
                found.append(hit)
            }
            return found
        }
        let zebra = await hits("zebra")
        expect(zebra.map(\.sessionID) == [s1], "a word said only mid-session is found")
        expect(zebra.first?.snippet.contains("zebra token") == true, "with its context")
        let quokka = await hits("Quokka")
        expect(quokka.map(\.sessionID) == [s2], "case-insensitively")
        let cyrillic = await hits("проверь")
        expect(cyrillic.map(\.sessionID) == [s1], "Cyrillic is found")
        let toolOutput = await hits("file contents that mention")
        expect(toolOutput.isEmpty, "tool output is never a hit")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
