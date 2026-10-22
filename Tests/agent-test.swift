import Foundation

@main
@MainActor
struct AgentTests {
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
        skillsReadTheirFrontMatter()
        projectSkillsShadowGlobalOnes()
        pathsStayWhereTheAgentLives()
        writesFollowTheAccessLevel()
        toolsFollowTheProfile()
        builtInToolsDeclareWhatTheyReach()
        riskDecidesExposure()
        consentPolicyTable()
        toolsetOffersInProviderOrder()
        toolsetAppliesTheProfile()
        batchesKeepCallOrder()
        budgetCutsLikeUpstream()
        elisionKeepsTheNewestRound()
        newFamiliesStartOff()
        anAgentsOwnRulesDecide()
        consentRulesSurviveARelaunch()
        thePromptCarriesTheFoldersContext()
        thePromptStatesTheAgentsOwnRules()
        agentsAndTheirChatsSurviveARelaunch()
        aPlanReadsAsAChecklist()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static let folder = "/Users/me/dev/project"
    static let home = "/Users/me"

    static func profile(_ access: AgentAccess = .workspaceWrite) -> AgentProfile {
        AgentProfile(name: "Builder", directory: folder, access: access)
    }

    static func tool(_ name: String, _ description: String = "") -> AITool {
        AITool(name: name, description: description, parameters: .object([:]), origin: "Test")
    }

    static func spec(_ name: String, _ family: AgentToolKind?, _ risk: AgentToolRisk) -> AgentToolSpec {
        AgentToolSpec(tool: tool(name), family: family, risk: risk, concurrent: false)
    }

    static func turn(_ agent: AgentProfile) -> AgentTurn {
        AgentTurn(
            profile: agent, skills: [], memoryURL: URL(fileURLWithPath: "/tmp/memory.md"),
            mode: .chat(UUID()))
    }

    static func skillsReadTheirFrontMatter() {
        let manifest = """
            ---
            name: deploy
            description: "Ship the app: build, sign, upload."
            license: MIT
            ---

            # Deploy
            Body text the model loads later.
            """
        let skill = AgentSkill.parse(manifest: manifest, directory: "/s/deploy", source: .project)
        expect(skill?.name == "deploy", "the name comes from the front matter")
        expect(
            skill?.description == "Ship the app: build, sign, upload.",
            "a quoted description keeps its colon and loses its quotes")
        expect(skill?.manifestPath == "/s/deploy/SKILL.md", "the manifest sits in the skill's folder")
        expect(
            AgentSkill.parse(manifest: "# No front matter", directory: "/s/x", source: .global) == nil,
            "a file without front matter is not a skill")
        expect(
            AgentSkill.parse(
                manifest: "---\ndescription: nameless\n---\n", directory: "/s/x", source: .global)
                == nil,
            "a skill must name itself")
    }

    static func projectSkillsShadowGlobalOnes() {
        let global = [
            AgentSkill(name: "deploy", description: "global", directory: "/g/deploy", source: .global),
            AgentSkill(name: "write", description: "global", directory: "/g/write", source: .global)
        ]
        let project = [
            AgentSkill(name: "deploy", description: "project", directory: "/p/deploy", source: .project)
        ]
        let catalog = AgentSkill.catalog(project: project, global: global, disabled: [])
        expect(catalog.map(\.name) == ["deploy", "write"], "one entry per name, sorted")
        expect(
            catalog.first?.source == .project, "the project's own skill wins over the global one")
        expect(
            AgentSkill.catalog(project: project, global: global, disabled: ["write"]).map(\.name)
                == ["deploy"],
            "a switched-off skill is left out")
    }

    static func pathsStayWhereTheAgentLives() {
        expect(
            AgentPathPolicy.resolve("src/main.swift", in: folder, home: home)
                == "/Users/me/dev/project/src/main.swift",
            "a relative path hangs off the agent's folder")
        expect(
            AgentPathPolicy.resolve("~/.agents/skills", in: folder, home: home)
                == "/Users/me/.agents/skills",
            "~ is home")
        let escape = AgentPathPolicy.resolve("../other/secret", in: folder, home: home)
        expect(escape == "/Users/me/dev/other/secret", ".. is resolved before anything is checked")
        expect(
            AgentPathPolicy.readable(escape, profile: profile(), extraRoots: [])
                != .allowed(escape),
            "climbing out of the folder is refused")
        expect(
            AgentPathPolicy.readable("/Users/me/dev/project-old/x", profile: profile(), extraRoots: [])
                != .allowed("/Users/me/dev/project-old/x"),
            "a sibling whose name starts the same is still outside")
        expect(
            AgentPathPolicy.readable(
                "/Users/me/.agents/skills/deploy/SKILL.md", profile: profile(),
                extraRoots: ["/Users/me/.agents/skills/deploy"])
                == .allowed("/Users/me/.agents/skills/deploy/SKILL.md"),
            "a granted skill's folder is readable from anywhere")
        expect(
            AgentPathPolicy.readable("/etc/hosts", profile: profile(.fullAccess), extraRoots: [])
                == .allowed("/etc/hosts"),
            "full access reads anywhere")
    }

    static func writesFollowTheAccessLevel() {
        let inside = folder + "/notes.md"
        expect(
            AgentPathPolicy.writable(inside, profile: profile(.readOnly)) != .allowed(inside),
            "a read-only agent writes nothing")
        expect(
            AgentPathPolicy.writable(inside, profile: profile()) == .allowed(inside),
            "a workspace agent writes inside its folder")
        expect(
            AgentPathPolicy.writable("/Users/me/.zshrc", profile: profile())
                != .allowed("/Users/me/.zshrc"),
            "and nowhere else")
        expect(
            AgentPathPolicy.writable("/Users/me/.zshrc", profile: profile(.fullAccess))
                == .allowed("/Users/me/.zshrc"),
            "full access writes anywhere")
    }

    static func toolsFollowTheProfile() {
        let names = { (agent: AgentProfile, skills: Bool) in
            Set(AgentToolbox.tools(for: agent, hasSkills: skills).map(\.name))
        }
        let readOnly = names(profile(.readOnly), false)
        expect(readOnly.contains(AgentToolbox.readFile), "a read-only agent still reads")
        expect(
            readOnly.isDisjoint(with: [
                AgentToolbox.writeFile, AgentToolbox.editFile, AgentToolbox.runCommand
            ]),
            "but is never offered a write or a command")
        let full = names(profile(), true)
        expect(
            full.isSuperset(of: [AgentToolbox.runCommand, AgentToolbox.loadSkill]),
            "a working agent with skills gets the terminal and load_skill")
        expect(!names(profile(), false).contains(AgentToolbox.loadSkill), "no skills, no load_skill")
        var quiet = profile()
        quiet.tools = [.memory]
        expect(
            names(quiet, false) == [AgentToolbox.readMemory, AgentToolbox.writeMemory],
            "only the families switched on are offered")
    }

    static func builtInToolsDeclareWhatTheyReach() {
        let tools = AgentToolbox.tools(for: profile(.fullAccess), hasSkills: true)
        let table: [String: (family: AgentToolKind?, risk: AgentToolRisk, concurrent: Bool)] = [
            AgentToolbox.listDirectory: (.files, .read, true),
            AgentToolbox.readFile: (.files, .read, true),
            AgentToolbox.searchFiles: (.files, .read, true),
            AgentToolbox.writeFile: (.files, .change, false),
            AgentToolbox.editFile: (.files, .change, false),
            AgentToolbox.runCommand: (.terminal, .execute, false),
            AgentToolbox.webFetch: (.web, .network, true),
            AgentToolbox.readMemory: (.memory, .read, true),
            AgentToolbox.writeMemory: (.memory, .own, false),
            AgentToolbox.loadSkill: (nil, .read, true)
        ]
        expect(tools.count == 10, "a full-access agent with skills is offered all ten built-ins")
        expect(Set(tools.map(\.name)) == Set(table.keys), "and each of them has a row in the table")
        for tool in tools {
            let spec = AgentToolbox.spec(for: tool)
            let row = table[tool.name]
            expect(
                spec.family == row?.family && spec.risk == row?.risk && spec.concurrent == row?.concurrent,
                "\(tool.name) declares its family, risk and whether it may share a round")
        }
        let unknown = AgentToolbox.spec(for: Self.tool("mystery"))
        expect(
            unknown.family == nil && unknown.risk == .execute && !unknown.concurrent,
            "a name the table misses is treated as the riskiest kind")
        expect(
            tools.allSatisfy { !$0.name.contains("__") },
            "no built-in name can be mistaken for an MCP server's tool")
    }

    static func riskDecidesExposure() {
        let readOnly: [AgentToolRisk: Bool] = [
            .read: true, .own: true, .network: true, .personal: true, .change: false, .execute: false
        ]
        for risk in AgentToolRisk.allCases {
            expect(
                risk.isOffered(to: .readOnly) == readOnly[risk],
                "a read-only agent \(readOnly[risk] == true ? "is" : "is not") offered \(risk)")
            for access in [AgentAccess.workspaceWrite, .fullAccess] {
                expect(risk.isOffered(to: access), "\(access) is offered \(risk)")
            }
        }
    }

    static func consentPolicyTable() {
        expect(
            AgentToolRisk.allCases.map(AgentConsentPolicy.defaultRule(for:))
                == [.always, .always, .always, .always, .ask, .ask],
            "by default only changes and commands stop to ask")
        let chat = AgentRunMode.chat(UUID())
        let alone = AgentRunMode.unattended(UUID())
        expect(AgentConsentPolicy.decide(.ask, mode: chat) == .ask, "in a chat, ask asks")
        expect(AgentConsentPolicy.decide(.ask, mode: alone) == .refuse, "with nobody there, ask refuses")
        for mode in [chat, alone] {
            expect(AgentConsentPolicy.decide(.always, mode: mode) == .allow, "always allows, watched or not")
            expect(AgentConsentPolicy.decide(.never, mode: mode) == .refuse, "never refuses, watched or not")
        }
        for risk in [AgentToolRisk.read, .own] {
            expect(
                AgentConsentPolicy.rule(for: risk, of: profile()) == .always,
                "reading and the agent's own notes never ask")
        }
    }

    static func toolsetOffersInProviderOrder() {
        let first = FakeProvider(offered: [spec("a_one", .files, .read), spec("a_two", nil, .own)])
        let second = FakeProvider(offered: [spec("b_one", .web, .network)])
        let build = {
            AgentToolset(
                turn: turn(profile()), providers: [first, second],
                mcpTools: [tool("srv__one"), tool("srv__two")],
                mcp: { .failure($0.id, "mcp") }, ask: { _, _ in false })
        }
        expect(
            build().tools.map(\.name) == ["a_one", "a_two", "b_one", "srv__one", "srv__two"],
            "providers in order, each in its own order, then MCP")
        expect(build().tools == build().tools, "the same inputs offer the same bytes, for prompt caching")
    }

    static func toolsetAppliesTheProfile() {
        var agent = profile(.readOnly)
        agent.tools = [.files]
        let first = FakeProvider(offered: [
            spec("off", .web, .network), spec("write", .files, .change), spec("look", .files, .read),
            AgentToolSpec(tool: tool("dup", "first"), family: nil, risk: .read, concurrent: true)
        ])
        let second = FakeProvider(offered: [
            AgentToolSpec(tool: tool("dup", "second"), family: nil, risk: .read, concurrent: true)
        ])
        let toolset = AgentToolset(
            turn: turn(agent), providers: [first, second], mcpTools: [tool("look", "mcp"), tool("srv__x")],
            mcp: { .failure($0.id, "mcp") }, ask: { _, _ in false })
        let names = toolset.tools.map(\.name)
        expect(!names.contains("off"), "a family switched off is not offered")
        expect(!names.contains("write"), "nor a change to a read-only agent")
        expect(
            toolset.tools.filter { $0.name == "dup" }.map(\.description) == ["first"],
            "a duplicate name goes to the first provider that offers it")
        expect(
            toolset.tools.filter { $0.name == "look" }.map(\.description) == [""],
            "and an MCP tool named like an agent tool loses to it")
        expect(toolset.isConcurrent("dup"), "a concurrent spec that never asks may share a round")
        expect(!toolset.isConcurrent("srv__x"), "MCP never does")
        expect(!toolset.isConcurrent("nope"), "nor a name nobody offered")
        let writer = AgentToolset(
            turn: turn(profile()),
            providers: [FakeProvider(offered: [
                AgentToolSpec(tool: tool("write"), family: .files, risk: .change, concurrent: true)
            ])],
            mcpTools: [], mcp: { .failure($0.id, "mcp") }, ask: { _, _ in false })
        expect(!writer.isConcurrent("write"), "a call whose rule can ask always runs alone")
    }

    static func batchesKeepCallOrder() {
        let (yes, no) = (true, false)
        expect(
            AgentBatchPolicy.batches([yes, yes, yes, no, yes], width: 4) == [0..<3, 3..<4, 4..<5],
            "neighbours that may share a round do, and a call that may not runs alone in its place")
        expect(
            AgentBatchPolicy.batches(Array(repeating: yes, count: 6), width: 4) == [0..<4, 4..<6],
            "a batch is never wider than its width")
        expect(
            AgentBatchPolicy.batches([yes, yes, no, yes], width: 1) == [0..<1, 1..<2, 2..<3, 3..<4],
            "width one runs every call alone")
        expect(AgentBatchPolicy.batches([], width: 4).isEmpty, "no calls, no batches")
        expect(AgentBatchPolicy.batches([no], width: 4) == [0..<1], "one call is one batch")
    }

    static func budgetCutsLikeUpstream() {
        var budget = AgentTurnBudget()
        let forty = String(repeating: "x", count: 40 * 1_024)
        let cut = budget.admit(AIToolResult(callID: "a", content: forty, isError: false))
        expect(
            cut.content == String(repeating: "x", count: AgentTurnBudget.resultBytes) + "\n…truncated.",
            "a result past 32 KB is cut there and says so")
        expect(budget.carried == cut.content.utf8.count, "what the turn carries is what was kept")
        for index in 1..<(AgentTurnBudget.turnResultBytes / AgentTurnBudget.resultBytes) {
            _ = budget.admit(AIToolResult(callID: "\(index)", content: forty, isError: false))
        }
        let over = budget.admit(AIToolResult(callID: "z", content: "hi", isError: false))
        expect(
            over.isError && over.content == "This turn's tool output budget is used up.",
            "past 512 KB in a turn, results are refused in upstream's words")
        var fresh = AgentTurnBudget()
        let almost = String(repeating: "x", count: AgentTurnBudget.resultBytes - 1)
        let split = fresh.admit(AIToolResult(callID: "m", content: almost + "йй", isError: false))
        expect(
            split.content == almost + "\n…truncated.",
            "a cut that lands inside a character keeps only whole ones")
    }

    static func elisionKeepsTheNewestRound() {
        func result(_ id: String, kilobytes: Int) -> AIMessage {
            AIMessage(
                role: .tool, text: "",
                toolResult: AIToolResult(
                    callID: id, content: String(repeating: "r", count: kilobytes * 1_024), isError: false))
        }
        func asking(_ ids: String...) -> AIMessage {
            AIMessage(
                role: .assistant, text: "",
                toolCalls: ids.map { AIToolCall(id: $0, name: "read_" + $0, arguments: "{}") })
        }
        let history = [AIMessage(role: .user, text: "go")]
        let small =
            history + [asking("a"), result("a", kilobytes: 50), asking("b"), result("b", kilobytes: 50)]
        var untouched = small
        expect(
            AgentTurnBudget.elide(&untouched, turnStart: 1, keepFrom: 3) == 0 && untouched == small,
            "under the watermark nothing changes, so the cached prefix holds")

        let full = history + [
            asking("a"), result("a", kilobytes: 50), asking("b", "c"), result("b", kilobytes: 50),
            result("c", kilobytes: 50), asking("d"), result("d", kilobytes: 30)
        ]
        var messages = full
        let saved = AgentTurnBudget.elide(&messages, turnStart: 1, keepFrom: 6)
        let contents = messages.compactMap(\.toolResult?.content)
        expect(
            contents[0].hasPrefix("[Earlier read_a result elided to save room: 51200 bytes.")
                && contents[1].hasPrefix("[Earlier read_b result elided"),
            "the oldest results are stubbed first, naming the tool and the size")
        expect(contents[2] == full[5].toolResult?.content, "and stop as soon as the turn fits again")
        expect(messages[6...] == full[6...], "the newest round is never touched")
        let total = contents.reduce(0) { $0 + $1.utf8.count }
        expect(total < AgentTurnBudget.elideTo, "what is left is under the low watermark")
        expect(
            saved == full.compactMap(\.toolResult?.content.utf8.count).reduce(0, +) - total,
            "and the saving is reported exactly")
        for (index, message) in messages.enumerated() {
            guard let id = message.toolResult?.callID else { continue }
            let asker = messages[..<index].last { $0.role == .assistant }
            expect(
                asker?.toolCalls.contains { $0.id == id } == true, "\(id) still follows the call that asked")
        }

        var again = messages + [asking("e"), result("e", kilobytes: 100)]
        _ = AgentTurnBudget.elide(&again, turnStart: 1, keepFrom: again.count - 2)
        expect(
            again[2].toolResult?.content == messages[2].toolResult?.content,
            "a stub is never stubbed again, so it keeps the size it reported")
    }

    static func anAgentsOwnRulesDecide() {
        var agent = profile()
        agent.consent = AgentConsentRules(risks: [.read: .never, .change: .always, .network: .never])
        expect(
            AgentConsentPolicy.rule(for: .read, of: agent) == .always,
            "reading never asks, whatever is stored")
        expect(AgentConsentPolicy.rule(for: .change, of: agent) == .always, "an agent's own rule wins")
        expect(AgentConsentPolicy.rule(for: .execute, of: agent) == .ask, "and the rest keep the default")
        let toolset = AgentToolset(
            turn: turn(agent),
            providers: [
                FakeProvider(offered: [spec("fetch", .web, .network), spec("write", .files, .change)])
            ],
            mcpTools: [], mcp: { .failure($0.id, "mcp") }, ask: { _, _ in false })
        expect(toolset.tools.map(\.name) == ["write"], "a tool whose rule is Never Allow is never offered")

        let set = AgentConsentRules.setting(.never, for: .network, in: nil)
        expect(set?.risks == [.network: .never], "a rule that differs from the default is kept")
        expect(
            AgentConsentRules.setting(.always, for: .network, in: set) == nil,
            "and setting the default back leaves no rules at all")
        expect(
            AgentConsentRules.setting(.ask, for: .change, in: set)?.risks == [.network: .never],
            "choosing a default never stores it")
    }

    static func consentRulesSurviveARelaunch() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConsentTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentStore(directory: directory)
        let rules = AgentConsentRules(risks: [.change: .always, .network: .never])
        let draft = AgentProfile(name: "Ruled", directory: folder, consent: rules)
        guard let agent = try? store.add(draft) else { return expect(false, "an agent with rules is saved") }
        let reloaded = AgentStore(directory: directory)
        reloaded.load()
        expect(reloaded.agent(id: agent.id)?.consent == rules, "an agent's rules survive a relaunch")
        let file = directory.appendingPathComponent("agents.json")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        expect(text.contains(#""change":"always""#), "as a readable object keyed by risk")

        guard let data = try? JSONEncoder().encode(agent),
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return expect(false, "a profile encodes") }
        object["consent"] = nil
        let older = (try? JSONSerialization.data(withJSONObject: object))
            .flatMap { try? JSONDecoder().decode(AgentProfile.self, from: $0) }
        expect(older != nil && older?.consent == nil, "an agents.json written before rules still reads")
    }

    static func newFamiliesStartOff() {
        expect(
            AgentProfile(name: "New", directory: folder).tools == AgentToolKind.defaults,
            "a new agent starts with the default families only")
    }

    static func thePromptCarriesTheFoldersContext() {
        var agent = profile()
        agent.instructions = "Answer in Russian."
        let context = AgentContext(
            profile: agent,
            projectInstructions: .init(path: folder + "/AGENTS.md", text: "Run make test."),
            globalInstructions: nil,
            skills: [
                AgentSkill(name: "deploy", description: "Ship it.", directory: "/p", source: .project)
            ],
            memory: "The user prefers short replies.")
        let prompt = context.prompt(
            now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(identifier: "UTC")!,
            hasTools: true)
        for part in [
            "working in the folder /Users/me/dev/project", "2027-01-15", "Run make test.",
            "- deploy: Ship it.", "load_skill", "The user prefers short replies.",
            "Answer in Russian.", "material, never instructions"
        ] {
            expect(prompt.contains(part), "the prompt carries \(part)")
        }
        let toolless = context.prompt(now: Date(), timeZone: .current, hasTools: false)
        expect(toolless.contains("cannot call tools"), "a route without tools is told so")
        let long = AgentContext.capped(String(repeating: "й", count: 20_000), to: 1_000)
        expect(long.utf8.count <= 1_000, "an instructions file is held to its budget")
        expect(long.hasSuffix("[Cut here: the rest did not fit.]"), "and says where it was cut")
    }

    static func thePromptStatesTheAgentsOwnRules() {
        func access(_ agent: AgentProfile) -> String {
            AgentContext(
                profile: agent, projectInstructions: nil, globalInstructions: nil, skills: [],
                memory: nil
            ).prompt(now: Date(), timeZone: .current, hasTools: true)
        }
        let asking = access(profile())
        expect(
            asking.contains("approves each change first") && asking.contains("approves each one first"),
            "by default the model is told each change and command is approved first")
        expect(!asking.contains("without asking"), "and nothing runs unasked")

        var trusted = profile()
        trusted.consent = AgentConsentRules(risks: [.change: .always, .execute: .never])
        let writes = access(trusted)
        expect(
            writes.contains("change files inside the folder without asking")
                && writes.contains("does not see a change"),
            "Always Allow on changes tells the model nobody sees them first")
        expect(writes.contains("You cannot run commands."), "Never Allow on commands leaves them out")
        expect(!writes.contains("approves"), "and no approval is promised that will not happen")

        var runner = profile(.fullAccess)
        runner.consent = AgentConsentRules(risks: [.change: .never, .execute: .always])
        let runs = access(runner)
        expect(
            runs.contains("you cannot change files") && runs.contains("run commands in the folder without asking"),
            "Always Allow on commands is stated, and a change it may not make is not offered")

        var noTerminal = profile(.fullAccess)
        noTerminal.tools = [.files]
        let filesOnly = access(noTerminal)
        expect(
            filesOnly.contains("change files anywhere") && filesOnly.contains("You cannot run commands."),
            "a family switched off is not described as a capability")
        expect(
            AgentConsentPolicy.rule(for: .execute, in: .terminal, of: noTerminal) == .never,
            "the prompt and the toolset read the same rule")

        var reader = profile(.readOnly)
        reader.consent = trusted.consent
        let reads = access(reader)
        expect(
            reads.contains("read-only") && !reads.contains("without asking"),
            "a read-only agent's stored rules grant it nothing")
        expect(
            AgentConsentPolicy.rule(for: .change, in: .files, of: reader) == .never,
            "nor does the policy offer it a change")
        expect(
            AgentConsentPolicy.rule(for: .network, in: nil, of: profile()) == .always,
            "a tool no switch governs follows the risk's rule")
        var noter = trusted
        noter.tools.insert(.notes)
        expect(
            AgentConsentPolicy.rule(for: .change, in: .files, of: noter) == .always
                && AgentConsentPolicy.rule(for: .change, in: .notes, of: noter) == .ask,
            "Always Allow on changes covers files, never an addition to the user's Notes")
    }

    static func agentsAndTheirChatsSurviveARelaunch() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentStore(directory: directory)
        expect((try? store.add(AgentProfile(name: " ", directory: folder))) == nil, "a name is required")
        expect((try? store.add(AgentProfile(name: "X", directory: ""))) == nil, "so is a folder")
        guard let agent = try? store.add(AgentProfile(name: "  Builder ", directory: folder)) else {
            return expect(false, "a valid agent is saved")
        }
        expect(agent.name == "Builder", "the name is trimmed")
        let chat = UUID()
        store.setAgent(agent.id, forChat: chat)

        let reloaded = AgentStore(directory: directory)
        reloaded.load()
        expect(reloaded.agents == [agent], "agents survive a relaunch")
        expect(reloaded.agent(forChat: chat) == agent, "and so does which chat talks to which")
        try? reloaded.remove(id: agent.id)
        expect(reloaded.agent(forChat: chat) == nil, "deleting an agent frees its chats")
        expect(
            reloaded.memoryURL(for: agent.id).path.contains(agent.id.uuidString.lowercased()),
            "each agent's notes live under its own id")
    }
}

/// `update_plan` and an ACP agent's plan read the same, and a malformed list shows nothing.
extension AgentTests {
    static func aPlanReadsAsAChecklist() {
        let items = AgentPlan.items(
            in: #"{"plan":[{"step":"Read the code","status":"completed"},"#
                + #"{"step":"Fix\nit","status":"in_progress"},{"step":"Ship","status":"later"},"#
                + #"{"step":"  ","status":"pending"},{"status":"pending"}]}"#)
        expect(
            items == [
                AgentPlan.Item(step: "Read the code", status: .completed),
                AgentPlan.Item(step: "Fix it", status: .inProgress),
                AgentPlan.Item(step: "Ship", status: .pending)
            ],
            "steps keep their order, a line break folds, an unknown status is pending, got \(items ?? [])")
        expect(
            AgentPlan.checklist(items ?? []) == "Plan:\n✓ Read the code\n→ Fix it\n· Ship\n",
            "and show as the checklist ACP plans show")
        expect(AgentPlan.items(in: #"{"plan":[]}"#) == nil, "an empty plan shows nothing")
        expect(AgentPlan.items(in: #"{"items":[{"step":"x"}]}"#) == nil, "nor does another shape")
        expect(AgentPlan.items(in: "not json") == nil, "nor text that is not JSON")
        let long = (0..<80).map { #"{"step":"\#($0)\#(String(repeating: "x", count: 400))"}"# }
        let capped = AgentPlan.items(in: #"{"plan":["# + long.joined(separator: ",") + "]}")
        expect(
            capped?.count == AgentPlan.maxSteps
                && capped?.allSatisfy { $0.step.count <= AgentPlan.maxStepLength } == true,
            "a plan is held to 50 steps of 300 characters")

        var mapper = ACPEventMapper(origin: "Agent")
        let entries = [
            ACPPlanEntry(.object(["content": .string("Read the code"), "status": .string("completed")]))!,
            ACPPlanEntry(.object(["content": .string("Fix it"), "status": .string("in_progress")]))!,
            ACPPlanEntry(.object(["content": .string("Ship")]))!
        ]
        expect(
            mapper.events(for: .plan(entries)) == [.reasoning(AgentPlan.checklist(items ?? []))],
            "an ACP agent's plan reads exactly like update_plan's")
        let tool = AgentPlan.definition(origin: "Builder")
        expect(
            tool.name == "update_plan" && !AgentToolbox.tools(for: profile(.fullAccess), hasSkills: true)
                .contains { $0.name == tool.name },
            "update_plan is a name no built-in uses")
    }
}

/// Offers what it is given; its calls are never run here.
struct FakeProvider: AgentToolProvider {
    let offered: [AgentToolSpec]

    func specs(for turn: AgentTurn) -> [AgentToolSpec] { offered }

    func run(_ call: AIToolCall, in context: AgentToolContext) async -> AIToolResult {
        .failure(call.id, "fake")
    }
}
