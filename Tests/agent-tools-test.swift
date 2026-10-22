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
        let firstAsk = await asked.last?.kind
        expect(firstAsk == .write, "having asked first")
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
        let commandAsk = await asked.last?.kind
        expect(commandAsk == .command, "after asking")
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

        expect(
            AgentHTML.text(from: "<html><script>x()</script><h1>Title</h1><p>A &amp; B</p></html>")
                == "Title\nA & B",
            "a page reads as its text, scripts dropped and entities decoded")

        try? String(repeating: "0123456789abcdef\n", count: 6_400).write(
            toFile: folder + "/big.txt", atomically: true, encoding: .utf8)
        let big = await agent.run(call(AgentToolbox.readFile, #"{"path":"big.txt"}"#))
        expect(
            big.content.utf8.count < AgentTurnBudget.resultBytes,
            "the executor's own cut stays under the loop's, so the loop never cuts it again")
        expect(big.content.contains("continue with offset"), "and still says where to continue")

        await throughTheToolset(folder: folder, memory: memory)

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    /// The built-ins behind the toolset: what a turn is offered, who is asked, where calls go.
    static func throughTheToolset(folder: String, memory: URL) async {
        let asks = AskRecorder()
        let mcp = MCPRecorder()
        func toolset(
            _ access: AgentAccess, mode: AgentRunMode = .chat(UUID()), allowing: Bool = true
        ) -> AgentToolset {
            AgentToolset(
                turn: AgentTurn(
                    profile: AgentProfile(name: "T", directory: folder, access: access), skills: [],
                    memoryURL: memory, mode: mode),
                providers: [AgentBuiltInTools()],
                mcpTools: [AITool(name: "srv__tool", description: "", parameters: .object([:]), origin: "srv")],
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
