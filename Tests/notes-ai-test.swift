import Foundation

@main
@MainActor
struct NotesAITests {
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

    static func main() async {
        definitionsAndSpecs()
        await throughTheToolset()
        mentions()
        appending()
        resolution()
        await searching()
        await reading()
        await appendingThroughTheRunner()
        await anUnnamedNoteByItsPrintedName()
        await openDraftRouting()
        attachments()
        await theStoreTakesAnAppend()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Fixtures

    static func folder(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-notes-ai-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Written oldest first, a minute apart, so the listing's order is the argument order reversed.
    static func write(_ notes: [(String, String)], in folder: URL) {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for (index, (name, source)) in notes.enumerated() {
            let url = folder.appendingPathComponent(name)
            try? Data(source.utf8).write(to: url)
            try? FileManager.default.setAttributes(
                [.modificationDate: start.addingTimeInterval(Double(index) * 60)], ofItemAtPath: url.path)
        }
    }

    static func text(_ name: String, in folder: URL) -> String? {
        try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    static func runner(
        _ folder: URL, canWrite: Bool = true, enabled: Bool = true, allowing: Bool = true,
        consents: ConsentLog = ConsentLog(), writer: NoteToolWriter = .fileOnly
    ) -> NoteToolRunner {
        NoteToolRunner(
            repository: NotesRepository(notesDirectory: folder), canWrite: canWrite,
            timeZone: TimeZone(identifier: "UTC") ?? .current, isEnabled: { enabled },
            consent: { await consents.record($0, answer: allowing) }, writer: writer)
    }

    static func call(_ name: String, _ arguments: String) -> AIToolCall {
        AIToolCall(id: UUID().uuidString, name: name, arguments: arguments)
    }

    static func profile(
        _ access: AgentAccess = .workspaceWrite, tools: Set<AgentToolKind> = [.notes],
        rules: AgentConsentRules? = nil
    ) -> AgentProfile {
        AgentProfile(name: "T", directory: "/tmp", access: access, tools: tools, consent: rules)
    }

    static func turn(_ profile: AgentProfile, mode: AgentRunMode = .chat(UUID())) -> AgentTurn {
        AgentTurn(
            profile: profile, skills: [], memoryURL: URL(fileURLWithPath: "/tmp/memory.md"), mode: mode)
    }

    static func provider(_ folder: URL, writer: NoteToolWriter = .fileOnly) -> NoteAgentTools {
        NoteAgentTools(
            repository: NotesRepository(notesDirectory: folder),
            timeZone: TimeZone(identifier: "UTC") ?? .current, isEnabled: { true }, writer: writer)
    }

    // MARK: - 1. Definitions and specs

    static func definitionsAndSpecs() {
        let writable = NoteTools.definitions(canWrite: true, origin: "Notes")
        let readOnly = NoteTools.definitions(canWrite: false, origin: "Notes")
        expect(
            writable.map(\.name) == [NoteTools.search, NoteTools.read, NoteTools.append],
            "a writable agent gets all three Notes tools")
        expect(
            readOnly.map(\.name) == [NoteTools.search, NoteTools.read], "a read-only one gets no append")
        expect(!writable.contains { $0.name.contains("__") }, "no name could be read as an MCP tool")
        for tool in writable {
            let schema = tool.parameters.objectValue
            expect(
                schema?["type"]?.stringValue == "object" && schema?["required"]?.arrayValue != nil,
                "\(tool.name) has an object schema with a required list")
            expect(tool.origin == "Notes" && tool.title == tool.name, "\(tool.name) reads Notes · name")
        }
        let required = writable.last?.parameters.objectValue?["required"]?.arrayValue?
            .compactMap(\.stringValue)
        expect(required == ["note", "text"], "notes_append requires note and text")
        expect(
            writable.last?.description.contains("The user is asked first.") == true,
            "the append's description says the user is asked, which no rule switches off")

        let specs = provider(folder("specs")).specs(for: turn(profile()))
        let table = Dictionary(uniqueKeysWithValues: specs.map { ($0.tool.name, $0) })
        expect(
            table[NoteTools.search]?.risk == .personal && table[NoteTools.search]?.concurrent == true
                && table[NoteTools.read]?.risk == .personal && table[NoteTools.read]?.concurrent == true,
            "reads are personal data with no effect, so they may share a round")
        expect(
            table[NoteTools.append]?.risk == .change && table[NoteTools.append]?.concurrent == false,
            "an append is a change that runs alone")
        expect(specs.allSatisfy { $0.family == .notes }, "the notes family switches all three")
        let builtIns = AgentToolbox.tools(
            for: profile(.fullAccess, tools: Set(AgentToolKind.allCases)), hasSkills: true
        ).map(\.name)
        expect(NoteTools.allNames.isDisjoint(with: builtIns), "no Notes name is a built-in's")
        expect(
            !AgentToolKind.defaults.contains(.notes)
                && !AgentProfile(name: "New", directory: "/tmp").tools.contains(.notes),
            "Notes is off for a new agent until ticked")
        let request = NoteAgentTools.request(
            for: NoteToolConsent(title: "Plan", creates: true, text: String(repeating: "x", count: 700)))
        expect(
            request.summary == "Create the note “Plan”" && request.detail.contains("…"),
            "the dialog names the note and previews a long text, got \(request.summary)")
        let adding = NoteAgentTools.request(for: NoteToolConsent(title: "Plan", creates: false, text: "x"))
        expect(adding.summary == "Add to “Plan”", "and says when it adds to one")
    }

    static func throughTheToolset() async {
        let root = folder("toolset")
        defer { try? FileManager.default.removeItem(at: root) }
        write([("Plan.md", "first\n")], in: root)
        let asks = AskLog()
        func toolset(_ profile: AgentProfile, mode: AgentRunMode = .chat(UUID())) -> AgentToolset {
            AgentToolset(
                turn: turn(profile, mode: mode), providers: [provider(root)], mcpTools: [],
                mcp: { .failure($0.id, "mcp") }, ask: { spec, _ in await asks.record(spec) })
        }
        expect(
            toolset(profile(tools: [.files])).tools.isEmpty,
            "an agent without the Notes family is offered none of its tools")
        expect(
            toolset(profile()).tools.map(\.name) == [NoteTools.search, NoteTools.read, NoteTools.append],
            "with it, all three")
        expect(
            toolset(profile(.readOnly)).tools.map(\.name) == [NoteTools.search, NoteTools.read],
            "a read-only agent is never offered the append")
        for rule in AgentConsentRule.allCases {
            let rules = AgentConsentRules.setting(rule, for: .change, in: nil)
            expect(
                AgentConsentPolicy.rule(for: .change, in: .notes, of: profile(rules: rules)) == .ask,
                "Changes set to \(rule) still leaves an addition to Notes asking")
        }
        let offered = toolset(profile())
        expect(
            offered.isConcurrent(NoteTools.search) && !offered.isConcurrent(NoteTools.append),
            "searches may run together, an append never")

        let quiet: @Sendable (AgentToolSignal) -> Void = { _ in }
        let searched = await offered.run(call(NoteTools.search, #"{"query":"first"}"#), signal: quiet)
        let askedForRead = await asks.count
        expect(!searched.isError && askedForRead == 0, "a search runs without asking")
        let appended = await offered.run(
            call(NoteTools.append, #"{"note":"Plan","text":"second"}"#), signal: quiet)
        let asked = await asks.last
        expect(
            !appended.isError && asked?.family == .notes && asked?.risk == .change,
            "an append asks as a change to notes, so a grant never covers files")
        expect(text("Plan.md", in: root) == "first\n\nsecond\n", "and then adds the text")
        let trusting = profile(tools: [.files, .notes], rules: AgentConsentRules(risks: [.change: .always]))
        let before = await asks.count
        _ = await toolset(trusting).run(
            call(NoteTools.append, #"{"note":"Plan","text":"third"}"#), signal: quiet)
        let after = await asks.count
        expect(
            after == before + 1 && text("Plan.md", in: root) == "first\n\nsecond\n\nthird\n",
            "Always Allow for file changes never makes an append silent")
        let barred = profile(tools: [.files, .notes], rules: AgentConsentRules(risks: [.change: .never]))
        expect(
            toolset(barred).tools.map(\.name).contains(NoteTools.append),
            "Never Allow for file changes leaves the append offered, still asking")
        let unattended = await toolset(trusting, mode: .unattended(UUID())).run(
            call(NoteTools.append, #"{"note":"Plan","text":"fourth"}"#), signal: quiet)
        expect(
            unattended.isError && text("Plan.md", in: root) == "first\n\nsecond\n\nthird\n",
            "with nobody to ask, an append is refused and the note stays, whatever Changes says")
    }

    // MARK: - 2. @note

    static func mentions() {
        expect(
            NoteMention.consume(old: "hi @note", new: "hi @note ", reservedAtStart: false) == "hi ",
            "a typed space after @note removes the token")
        expect(
            NoteMention.consume(old: "@note", new: "@note ", reservedAtStart: false) == "",
            "at the start of an empty draft too")
        expect(
            NoteMention.consume(old: "mail@note", new: "mail@note ", reservedAtStart: false) == nil,
            "not inside a word")
        expect(
            NoteMention.consume(old: "x ", new: "x @note y", reservedAtStart: false) == nil,
            "a paste never triggers")
        expect(
            NoteMention.consume(old: "x @note ", new: "x @note", reservedAtStart: false) == nil,
            "deleting never triggers")
        expect(
            NoteMention.consume(old: "x", new: "x @note ", reservedAtStart: false) == nil,
            "putting the token back never triggers again")
        expect(
            NoteMention.consume(old: " @note", new: " @note ", reservedAtStart: true) == nil,
            "an MCP server slugged note keeps the start of the draft")
        expect(
            NoteMention.consume(old: "ask @note", new: "ask @note ", reservedAtStart: true) == "ask ",
            "but not the middle")
    }

    // MARK: - 3. Appending

    static func appending() {
        expect(NoteToolFormat.appending("text", to: "") == "text\n", "an empty note takes the text")
        expect(
            NoteToolFormat.appending("text", to: "body") == "body\n\ntext\n",
            "a note without a final newline gets a blank line first")
        expect(NoteToolFormat.appending("text", to: "body\n") == "body\n\ntext\n", "one newline gets one")
        expect(NoteToolFormat.appending("text\n", to: "body\n\n") == "body\n\ntext\n", "two get none")
        expect(NoteToolFormat.newTitle("a/b.md") == "a-b", "a slash cannot reach the file name")
        expect(NoteToolFormat.newTitle(" .hidden") == "hidden", "nor a leading dot")
        expect(NoteToolFormat.newTitle("  ") == nil, "a blank title is none")
    }

    // MARK: - 4. Resolution

    static func summary(_ file: String, firstLine: String? = nil, minutes: Double = 0) -> NoteSummary {
        NoteSummary(
            id: NoteID(rawValue: file), title: (file as NSString).deletingPathExtension,
            firstLine: firstLine, modifiedAt: Date(timeIntervalSince1970: 1_790_000_000 + minutes * 60))
    }

    static func resolution() {
        let plan = summary("Plán.md")
        let standup = summary("Standup.md")
        let one = summary("Untitled.md", firstLine: "Groceries")
        let two = summary("Untitled 2.md", firstLine: "Ideas")
        let three = summary("Untitled 3.md", firstLine: "Ideas")
        let all = [plan, standup, one, two, three]
        expect(NoteToolFormat.resolve("Standup.md", in: all) == .found(standup), "by file name")
        expect(NoteToolFormat.resolve("Untitled 2", in: all) == .found(two), "by file name without .md")
        expect(NoteToolFormat.resolve("plan", in: all) == .found(plan), "by title, case and accents folded")
        expect(
            NoteToolFormat.resolve("groceries", in: all) == .found(one), "an unnamed note by its first line")
        expect(
            NoteToolFormat.resolve("Ideas", in: all) == .ambiguous([two, three]),
            "two such lines are ambiguous")
        guard case .missing(let suggestions) = NoteToolFormat.resolve("stand", in: all) else {
            return expect(false, "a partial title is not a match")
        }
        expect(suggestions.first == "Standup" && suggestions.count <= 5, "but suggests close titles")
        expect(NoteToolFormat.name(two) == "Ideas (Untitled 2.md)", "an unnamed note is named with its file")
        for note in all {
            expect(
                NoteToolFormat.resolve(NoteToolFormat.name(note), in: all) == .found(note),
                "the name a tool prints finds its note again: \(NoteToolFormat.name(note))")
        }
        expect(
            NoteToolFormat.resolve("Ideas, edited (Untitled 3.md)", in: all) == .found(three),
            "by its file even after its first line changed")
        let titled = summary("Plan (Standup.md).md")
        expect(
            NoteToolFormat.resolve("Plan (Standup.md)", in: all + [titled]) == .found(titled),
            "a title that merely looks like that form is still its own file first")
        expect(
            NoteToolFormat.row(standup, timeZone: TimeZone(identifier: "UTC") ?? .current)
                == "Standup · modified 2026-09-21 14:13",
            "a row carries an absolute date in the given zone")
    }

    // MARK: - 5. Search

    static func searching() async {
        let root = folder("search")
        defer { try? FileManager.default.removeItem(at: root) }
        write(
            [
                ("Weekly.md", "Agenda\nthe standup moved to 10:30\n"),
                ("Standup.md", "blocked on the API review until Thursday\n"),
                ("Groceries.md", "milk\n")
            ], in: root)
        try? Data([0xFF, 0xFE, 0x00, 0x41]).write(to: root.appendingPathComponent("Broken.md"))
        let notes = runner(root)
        let found = await notes.run(call(NoteTools.search, #"{"query":"standup"}"#))
        expect(!found.isError && found.content.hasPrefix("2 notes match “standup”:"), "counts the matches")
        let standup = found.content.range(of: "- Standup")
        let weekly = found.content.range(of: "- Weekly")
        expect(
            standup != nil && weekly != nil && standup!.lowerBound < weekly!.lowerBound,
            "a title match outranks a body match")
        expect(found.content.contains("  > the standup moved to 10:30"), "a body match shows its line")
        expect(found.content.hasSuffix("Read one with notes_read."), "and says how to read one")
        let body = await notes.run(call(NoteTools.search, #"{"query":"thursday"}"#))
        expect(
            body.content.contains("> blocked on the API review until Thursday"),
            "a word only in the body finds its note, past an unreadable file")
        let none = await notes.run(call(NoteTools.search, #"{"query":"zebra"}"#))
        expect(none.content == "No note matches “zebra”.", "an empty search says so")

        let newest = await notes.run(call(NoteTools.search, "{}"))
        let order = ["- Broken", "- Groceries", "- Standup", "- Weekly"].compactMap {
            newest.content.range(of: $0)?.lowerBound
        }
        expect(
            newest.content.hasPrefix("The 4 newest notes:\n") && order.count == 4 && order == order.sorted(),
            "an empty query lists the newest first, a file that is not UTF-8 by its name")
        let crowded = folder("crowded")
        defer { try? FileManager.default.removeItem(at: crowded) }
        write((1...35).map { ("Note \($0).md", "word \($0)\n") }, in: crowded)
        let few = await runner(crowded).run(call(NoteTools.search, #"{"limit":0}"#))
        expect(few.content.hasPrefix("The newest note:\n- Note 35"), "a limit of 0 still shows one")
        let many = await runner(crowded).run(call(NoteTools.search, #"{"query":"word","limit":50}"#))
        expect(
            many.content.components(separatedBy: "\n- ").count - 1 == 30
                && many.content.contains("… 5 more"),
            "a limit of 50 is held to 30 and says what it left out")
        let huge = await runner(crowded).run(call(NoteTools.search, #"{"limit":1e300}"#))
        expect(!huge.isError, "an absurd limit is clamped, never trapped on")

        let task = Task { await runner(crowded).run(call(NoteTools.search, #"{"query":"word"}"#)) }
        task.cancel()
        let stopped = await task.value
        expect(stopped.content.hasPrefix("No note matches"), "a cancelled search stops reading notes")
    }

    // MARK: - 6. Read

    static func reading() async {
        let root = folder("read")
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = (1...50).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let long = (1...2_000).map { _ in String(repeating: "x", count: 100) }.joined(separator: "\n")
        write([("Log.md", lines), ("Huge.md", long), ("Empty.md", "")], in: root)
        let notes = runner(root)
        let page = await notes.run(call(NoteTools.read, #"{"note":"log","offset":5,"limit":3}"#))
        expect(
            page.content.hasPrefix("Note: Log (Log.md) · modified ")
                && page.content.contains(" · 50 lines\n---\nline 5\nline 6\nline 7\n"),
            "reads a page of lines with a header, got \(page.content)")
        expect(
            page.content.hasSuffix("… 43 more lines; continue with offset 8."),
            "and says where to continue")
        let rest = await notes.run(call(NoteTools.read, #"{"note":"Log.md","offset":45}"#))
        expect(rest.content.hasSuffix("line 50\n"), "the last page ends without a continuation")
        let past = await notes.run(call(NoteTools.read, #"{"note":"Log","offset":51}"#))
        expect(past.isError && past.content.contains("past the end"), "an offset past the end fails")
        let huge = await notes.run(call(NoteTools.read, #"{"note":"Huge"}"#))
        expect(
            huge.content.utf8.count <= NoteTools.maxOutputBytes
                && huge.content.utf8.count < AgentTurnBudget.resultBytes
                && huge.content.contains("continue with offset"),
            "a long note is cut under 28 KB and says where to continue")
        let empty = await notes.run(call(NoteTools.read, #"{"note":"Empty"}"#))
        expect(empty.content.hasSuffix("· 0 lines\n---\n(empty)"), "an empty note says so")
        let missing = await notes.run(call(NoteTools.read, #"{"note":"Lgo"}"#))
        expect(
            missing.isError && missing.content.hasPrefix("No note is called “Lgo”."),
            "a missing note fails with suggestions")
        let unnamed = await notes.run(call(NoteTools.read, "{}"))
        expect(unnamed.content == "The note argument is required.", "the note is required")
    }

    // MARK: - 7. Append

    static func appendingThroughTheRunner() async {
        let root = folder("append")
        defer { try? FileManager.default.removeItem(at: root) }
        write([("Report.md", "# Report\nfirst")], in: root)
        let consents = ConsentLog()
        let declined = await runner(root, allowing: false, consents: consents).run(
            call(NoteTools.append, #"{"note":"Report","text":"more"}"#))
        let asked = await consents.last
        expect(
            asked == NoteToolConsent(title: "Report", creates: false, text: "more"),
            "the consent carries the title, whether it creates, and the text")
        expect(
            declined.isError && declined.content == NoteToolRunner.declined
                && text("Report.md", in: root) == "# Report\nfirst",
            "a refusal leaves the file byte for byte")
        let added = await runner(root).run(call(NoteTools.append, #"{"note":"report","text":"more"}"#))
        expect(
            added.content == "Added 4 bytes to “Report”."
                && text("Report.md", in: root) == "# Report\nfirst\n\nmore\n",
            "a case-different title adds to the note with one blank line, got \(added.content)")
        expect(
            (try? FileManager.default.contentsOfDirectory(atPath: root.path).count) == 1,
            "and never makes a duplicate")

        let created = await runner(root, consents: consents).run(
            call(NoteTools.append, #"{"note":"Weekly report","text":"done"}"#))
        let creating = await consents.last
        expect(
            created.content == "Created “Weekly report” (Weekly report.md)."
                && text("Weekly report.md", in: root) == "done\n" && creating?.creates == true,
            "a missing note is created after asking to create it")
        let slashed = await runner(root, consents: consents).run(
            call(NoteTools.append, #"{"note":"Q3/Q4","text":"x"}"#))
        let slashedTitle = await consents.last?.title
        expect(
            slashedTitle == "Q3-Q4" && text("Q3-Q4.md", in: root) == "x\n" && !slashed.isError,
            "a title the folder cannot take is asked about as it will be made")
        let strict = await runner(root).run(
            call(NoteTools.append, #"{"note":"Nowhere","text":"x","create":false}"#))
        expect(
            strict.isError && strict.content.hasPrefix("No note is called “Nowhere”.")
                && text("Nowhere.md", in: root) == nil,
            "create false fails instead of making a note")
        let readOnly = await runner(root, canWrite: false).run(
            call(NoteTools.append, #"{"note":"Report","text":"x"}"#))
        expect(
            readOnly.content == "This agent is read-only and cannot change notes.",
            "a read-only agent cannot append even when it calls the tool")
        let big = String(repeating: "x", count: NoteTools.maxAppendBytes + 1)
        let arguments = String(
            data: (try? JSONSerialization.data(withJSONObject: ["note": "Report", "text": big])) ?? Data(),
            encoding: .utf8) ?? "{}"
        let tooBig = await runner(root).run(call(NoteTools.append, arguments))
        expect(tooBig.content == "text is over 64 KB; add it in parts.", "64 KB and a byte is refused")
        expect(text("Report.md", in: root) == "# Report\nfirst\n\nmore\n", "and nothing was written")

        let off = runner(root, enabled: false)
        for name in [NoteTools.search, NoteTools.read, NoteTools.append] {
            let result = await off.run(call(name, #"{"note":"Report","text":"x"}"#))
            expect(result.content == NoteToolRunner.turnedOff, "\(name) refuses while Notes is off")
        }
    }

    static func anUnnamedNoteByItsPrintedName() async {
        let root = folder("unnamed")
        defer { try? FileManager.default.removeItem(at: root) }
        write([("Untitled 2.md", "Ideas for Q4\nship it\n")], in: root)
        let notes = runner(root)
        let listed = await notes.run(call(NoteTools.search, "{}"))
        let row = listed.content.components(separatedBy: "\n").first { $0.hasPrefix("- ") }
        let printed = row.flatMap { $0.dropFirst(2).components(separatedBy: " · modified").first } ?? ""
        expect(
            printed == "Ideas for Q4 (Untitled 2.md)", "the search names it by line and file, got \(printed)")
        let arguments = { (extra: String) in
            let object = ["note": printed, "text": extra]
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        let read = await notes.run(call(NoteTools.read, arguments("")))
        expect(!read.isError && read.content.contains("ship it"), "notes_read takes that name back")
        let added = await notes.run(call(NoteTools.append, arguments("more")))
        expect(
            added.content == "Added 4 bytes to “Ideas for Q4”."
                && text("Untitled 2.md", in: root) == "Ideas for Q4\nship it\n\nmore\n"
                && (try? FileManager.default.contentsOfDirectory(atPath: root.path).count) == 1,
            "and notes_append adds to that note rather than making a new one, got \(added.content)")
    }

    // MARK: - 8. The open note

    static func openDraftRouting() async {
        let root = folder("draft")
        defer { try? FileManager.default.removeItem(at: root) }
        write([("Open.md", "draft")], in: root)
        let writes = WriteLog()
        let open = NoteToolWriter(
            amendOpenDraft: { id, onDisk, change in await writes.amend(id, onDisk, change(onDisk)) },
            didWrite: { await writes.wrote($0) })
        let result = await runner(root, writer: open).run(
            call(NoteTools.append, #"{"note":"Open","text":"agent"}"#))
        let amended = await writes.amended
        let wrote = await writes.written
        expect(
            !result.isError && amended == ["draft → draft\n\nagent\n"] && wrote.isEmpty
                && text("Open.md", in: root) == "draft",
            "an open draft takes the text and the file is left to its autosave")

        let closed = NoteToolWriter(
            amendOpenDraft: { _, _, _ in false }, didWrite: { await writes.wrote($0) })
        _ = await runner(root, writer: closed).run(call(NoteTools.append, #"{"note":"Open","text":"x"}"#))
        _ = await runner(root, writer: closed).run(call(NoteTools.append, #"{"note":"New","text":"y"}"#))
        let after = await writes.written
        expect(
            after == [NoteID(rawValue: "Open.md"), NoteID(rawValue: "New.md")],
            "each file write is reported exactly once")
    }

    // MARK: - 9. Attaching

    static func attachments() {
        let limit = AIAttachmentBudget.maxInlinedTextBytes
        guard case .document(let document) = NoteAttachmentPolicy.document(title: "Plan", source: "café")
        else { return expect(false, "a short note attaches") }
        expect(
            document.name == "Plan.md" && document.mimeType == "text/plain"
                && document.data == Data("café".utf8),
            "as a Markdown text file of its UTF-8 bytes")
        expect(
            NoteAttachmentPolicy.document(title: "A", source: String(repeating: "x", count: limit))
                != .tooLong,
            "exactly 32 KB fits")
        expect(
            NoteAttachmentPolicy.document(title: "A", source: String(repeating: "x", count: limit + 1))
                == .tooLong,
            "a byte more is refused, not cut")
        expect(
            NoteAttachmentPolicy.document(title: "A", source: String(repeating: "é", count: limit / 2 + 1))
                == .tooLong,
            "measured in bytes, not characters")
    }

    // MARK: - 10. The store

    static func theStoreTakesAnAppend() async {
        let root = folder("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(repository: NotesRepository(notesDirectory: root))
        expect(
            !store.amendDraft(of: NoteID(rawValue: "Untitled.md"), onDisk: "") { $0 },
            "an unloaded store takes nothing")
        _ = await store.create()
        guard let active = store.activeID else { return expect(false, "the store opens a note") }
        store.updateSource("typed")
        _ = await store.flush()
        let epoch = store.editorEpoch
        expect(
            !store.amendDraft(of: NoteID(rawValue: "Other.md"), onDisk: "typed") { $0 + "!" },
            "another note is not amended")
        let runner = runner(root, writer: .through(store))
        let result = await runner.run(call(NoteTools.append, #"{"note":"Untitled.md","text":"agent"}"#))
        expect(
            !result.isError && store.source == "typed\n\nagent\n" && store.isDirty
                && store.editorEpoch == epoch + 1,
            "an append to the open note joins its draft and starts a new editor epoch")
        expect(text(active.rawValue, in: root) == "typed", "before any write")
        _ = await waitUntil { !store.isDirty }
        expect(
            text(active.rawValue, in: root) == "typed\n\nagent\n", "and the autosave writes the joined text")

        _ = await runner.run(call(NoteTools.append, #"{"note":"Elsewhere","text":"x"}"#))
        _ = await waitUntil { store.summaries.count == 2 }
        expect(
            store.summaries.contains { $0.id.rawValue == "Elsewhere.md" } && store.activeID == active,
            "a note written on disk is listed by the open store, which keeps its note")

        // The Notes window hides without unloading the store, so its clean draft can fall behind.
        let file = root.appendingPathComponent(active.rawValue)
        try? Data("typed\n\nagent\nedited while hidden\n".utf8).write(to: file)
        let behind = await runner.run(call(NoteTools.append, #"{"note":"Untitled.md","text":"later"}"#))
        let joined = "typed\n\nagent\nedited while hidden\n\nlater\n"
        expect(
            !behind.isError && text(active.rawValue, in: root) == joined,
            "a clean draft the file moved past leaves the append to the file, which keeps the edit")
        _ = await waitUntil { store.source == joined }
        expect(
            store.source == joined && !store.isDirty && store.activeID == active,
            "and the store reloads that note from the file")
        try? await Task.sleep(for: .milliseconds(400))
        expect(text(active.rawValue, in: root) == joined, "and no stale autosave follows")

        store.updateSource(joined + "typing")
        let typing = await runner.run(call(NoteTools.append, #"{"note":"Untitled.md","text":"mid"}"#))
        expect(
            !typing.isError && store.source == joined + "typing\n\nmid\n"
                && text(active.rawValue, in: root) == joined,
            "an unsaved draft takes the append though the file differs")
        _ = await waitUntil { !store.isDirty }
        expect(
            text(active.rawValue, in: root) == joined + "typing\n\nmid\n",
            "and its autosave writes both")
    }

    static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

/// Answers every append's question as told, remembering what it was asked.
actor ConsentLog {
    private(set) var asked: [NoteToolConsent] = []

    var last: NoteToolConsent? { asked.last }

    func record(_ consent: NoteToolConsent, answer: Bool) -> Bool {
        asked.append(consent)
        return answer
    }
}

/// Stands in for the toolset's dialog.
actor AskLog {
    private var asked: [AgentGrant] = []

    var count: Int { asked.count }
    var last: AgentGrant? { asked.last }

    func record(_ spec: AgentToolSpec) -> Bool {
        asked.append(spec.grant)
        return true
    }
}

/// What a writer was handed: amended drafts and reported file writes.
actor WriteLog {
    private(set) var amended: [String] = []
    private(set) var written: [NoteID] = []

    func amend(_ id: NoteID, _ onDisk: String, _ joined: String) -> Bool {
        amended.append("\(onDisk) → \(joined)")
        return true
    }

    func wrote(_ id: NoteID) {
        written.append(id)
    }
}
