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
        newerFamiliesStayOutOfOlderBuildsWay()
        aColourSurvivesTheOlderBuildsRewrite()
        aToolsetCanOfferReadingOnly()
        compactionCoversWhatTheBudgetDrops()
        compactionNotesRideTheFirstQuestion()
        compactionNotesAreKeptPerChat()
        readingToolsDescribeTheirReach()
        spotlightQueriesAreBuiltNotWritten()

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
            "in the folder /Users/me/dev/project",
            "time zone is \(TimeZone(identifier: "UTC")!.identifier) (UTC+00:00)", "Run make test.",
            "- deploy: Ship it.", "load_skill", "The user prefers short replies.",
            "Answer in Russian.", "material, never instructions"
        ] {
            expect(prompt.contains(part), "the prompt carries \(part)")
        }
        expect(!prompt.contains("2027"), "and no date, which would change the cached prompt every day")
        let moscow = TimeZone(identifier: "Europe/Moscow")!
        expect(
            AgentTurnLead.opening(
                now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: moscow,
                budget: AgentEffort.balanced.budget, effort: "Balanced effort")
                == "[Now: Friday 2027-01-15 11:00, Europe/Moscow. Balanced effort: up to 25 rounds of tool calls.]",
            "the date and time lead the turn instead, with what the run may do")
        let toolless = context.prompt(now: Date(), timeZone: .current, hasTools: false)
        expect(toolless.contains("cannot call tools"), "a route without tools is told so")
        expect(
            prompt.contains("a general assistant") && prompt.contains("Match the effort to the task")
                && prompt.contains("Answer a simple question directly") && prompt.contains("Stop as soon as")
                && prompt.contains("search with web_search, then read the best result with web_fetch")
                && !toolless.contains("How to work"),
            "a general assistant's method, calibrated to the task, where it has tools to work with")
        let standing = context.prompt(
            now: Date(), timeZone: .current, hasTools: true, standing: ["Reply in haiku."])
        let order = ["## How to work", "Run make test.", "## Skills", "Answer in Russian.", "Reply in haiku.",
            "The user prefers short replies."].compactMap { standing.range(of: $0)?.lowerBound }
        expect(
            order.count == 6 && order == order.sorted(),
            "steady parts first, the user's standing text next, the agent's notes, which change most, last")
        var offline = agent
        offline.tools.remove(.web)
        expect(
            AgentContext(profile: offline, projectInstructions: nil, globalInstructions: nil, skills: [], memory: nil)
                .prompt(now: Date(), timeZone: .current, hasTools: true).contains("no web search of your own"),
            "and one without the web is told it has none")
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
        let deleted = UUID()
        store.setAgent(agent.id, forChat: chat)
        store.setAgent(agent.id, forChat: deleted)
        store.unbind([deleted, UUID()])

        let reloaded = AgentStore(directory: directory)
        reloaded.load()
        expect(reloaded.agents == [agent], "agents survive a relaunch")
        expect(reloaded.agent(forChat: chat) == agent, "and so does which chat talks to which")
        expect(
            reloaded.agent(forChat: deleted) == nil && reloaded.chatAgents.count == 1,
            "a chat that is gone leaves no binding behind")
        let untouched = directory.appendingPathComponent("untouched")
        AgentStore(directory: untouched).unbind([UUID()])
        AgentStore(directory: untouched).forgetPersonal([UUID()])
        expect(
            !FileManager.default.fileExists(atPath: untouched.appendingPathComponent("agent-chats.json").path)
                && !FileManager.default.fileExists(
                    atPath: untouched.appendingPathComponent("agent-personal-chats.json").path),
            "unbinding a chat that had no agent, or forgetting one never marked, writes nothing")

        let other = UUID()
        store.notePersonal(forChat: chat)
        store.notePersonal(forChat: chat)
        store.notePersonal(forChat: other)
        let marked = AgentStore(directory: directory)
        marked.load()
        expect(marked.personalChats == [chat, other], "a chat that read the user's data stays marked across a relaunch")
        marked.forgetPersonal([other, UUID()])
        let pruned = AgentStore(directory: directory)
        pruned.load()
        expect(pruned.personalChats == [chat], "and loses its mark only when it is gone")
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

/// Screen and Sub-agents are written where the previous build, which knows neither, never looks.
extension AgentTests {
    static func newerFamiliesStayOutOfOlderBuildsWay() {
        var agent = profile()
        agent.tools = [.files, .notes, .screen, .delegate]
        guard let data = try? JSONEncoder().encode(agent),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return expect(false, "a profile encodes") }
        let legacy: Set<String> = ["files", "terminal", "web", "memory", "notes"]
        expect(
            Set(object["tools"] as? [String] ?? []) == ["files", "notes"],
            "tools holds only the families the previous build can decode")
        expect(
            Set(object["addedTools"] as? [String] ?? []) == ["screen", "delegate"],
            "and the newer ones ride their own key, which that build ignores")
        let decoded = try? JSONDecoder().decode(AgentProfile.self, from: data)
        expect(decoded == agent, "both come back as one set")
        expect(
            (try? JSONEncoder().encode(profile())).flatMap { String(data: $0, encoding: .utf8) }?
                .contains("addedTools") == false,
            "an agent without them writes no extra key")
        expect(
            Set(AgentToolKind.allCases.map(\.rawValue)).subtracting(legacy)
                == Set(AgentToolKind.unknownToOlderBuilds.map(\.rawValue)),
            "every family the previous build lacks is kept out of tools")
        var future = object
        future["addedTools"] = ["screen", "telepathy"]
        let later = (try? JSONSerialization.data(withJSONObject: future))
            .flatMap { try? JSONDecoder().decode(AgentProfile.self, from: $0) }
        expect(
            later?.tools == [.files, .notes, .screen],
            "and a family from a newer build is dropped rather than losing the agent")
        expect(
            AgentToolKind.defaults.isDisjoint(with: AgentToolKind.unknownToOlderBuilds),
            "neither starts on for a new agent")
        newerFamiliesSurviveTheOlderBuildsRewrite()
    }

    /// What the previous build's generated `Codable` does to agents.json: unknown keys are dropped.
    static func rewriteAsOlderBuild(_ file: URL) {
        guard let data = try? Data(contentsOf: file),
            var objects = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return }
        for index in objects.indices {
            objects[index]["addedTools"] = nil
            objects[index]["color"] = nil
        }
        try? JSONSerialization.data(withJSONObject: objects).write(to: file)
    }

    static func newerFamiliesSurviveTheOlderBuildsRewrite() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentNewerTools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agents.json")
        let store = AgentStore(directory: directory)
        var draft = AgentProfile(name: "Rig", directory: folder)
        draft.tools = [.files, .screen, .delegate]
        guard var agent = try? store.add(draft),
            let plain = try? store.add(AgentProfile(name: "Plain", directory: folder))
        else { return expect(false, "two agents are saved") }
        func reloaded() -> AgentStore {
            let store = AgentStore(directory: directory)
            store.load()
            return store
        }
        rewriteAsOlderBuild(file)
        expect(
            reloaded().agent(id: agent.id)?.tools == [.files, .screen, .delegate]
                && reloaded().agent(id: plain.id)?.tools == AgentToolKind.defaults,
            "an agents.json the previous build rewrote gets Screen and Sub-agents back, and only where set")
        agent.tools = [.files, .delegate]
        try? store.update(agent)
        rewriteAsOlderBuild(file)
        expect(
            reloaded().agent(id: agent.id)?.tools == [.files, .delegate],
            "a family unticked since stays unticked")
        agent.tools = [.files]
        try? store.update(agent)
        let side = directory.appendingPathComponent("agent-newer-tools.json")
        expect(!FileManager.default.fileExists(atPath: side.path), "with none left, the side file goes")
        rewriteAsOlderBuild(file)
        expect(reloaded().agent(id: agent.id)?.tools == [.files], "and nothing comes back")
    }

    /// Fork: an agent's colour is an optional key, and a side file brings it back after a rewrite.
    static func aColourSurvivesTheOlderBuildsRewrite() {
        var coloured = profile()
        coloured.color = "purple"
        let encoded = (try? JSONEncoder().encode(coloured)).flatMap { String(data: $0, encoding: .utf8) }
        expect(encoded?.contains("\"color\":\"purple\"") == true, "a colour rides its own optional key")
        expect(
            (try? JSONEncoder().encode(profile())).flatMap { String(data: $0, encoding: .utf8) }?
                .contains("\"color\"") == false,
            "an agent on its derived colour writes no key")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentColor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agents.json")
        let side = directory.appendingPathComponent("agent-colors.json")
        let store = AgentStore(directory: directory)
        var draft = AgentProfile(name: "Painted", directory: folder)
        draft.color = "magenta"
        guard var agent = try? store.add(draft),
            let plain = try? store.add(AgentProfile(name: "Plain", directory: folder))
        else { return expect(false, "two agents are saved") }
        func reloaded() -> AgentStore {
            let store = AgentStore(directory: directory)
            store.load()
            return store
        }
        rewriteAsOlderBuild(file)
        expect(
            reloaded().agent(id: agent.id)?.color == "magenta"
                && reloaded().agent(id: plain.id)?.color == nil,
            "an agents.json the previous build rewrote gets the colour back, and only where set")
        agent.color = nil
        try? store.update(agent)
        expect(!FileManager.default.fileExists(atPath: side.path), "with no colour left, the side file goes")
        rewriteAsOlderBuild(file)
        expect(reloaded().agent(id: agent.id)?.color == nil, "and a colour put back to derived stays so")
    }

    static func aToolsetCanOfferReadingOnly() {
        var agent = profile(.fullAccess)
        agent.tools = Set(AgentToolKind.allCases)
        let everything = FakeProvider(
            offered: AgentToolRisk.allCases.map { spec("t_\($0.rawValue)", nil, $0) })
        let reading = AgentToolset(
            turn: turn(agent), providers: [everything], mcpTools: [], offering: AgentToolRisk.reads,
            mcp: { .failure($0.id, "mcp") }, ask: { _, _ in false })
        expect(
            reading.tools.map(\.name) == ["t_read", "t_network", "t_personal"],
            "a sub-agent's toolset offers what reads and nothing that changes, writes or runs")
        let titled = TitledProvider()
        let routed = AgentToolset(
            turn: turn(agent), providers: [titled, everything], mcpTools: [tool("srv__x")],
            mcp: { .failure($0.id, "mcp") }, ask: { _, _ in false })
        let named = AIToolCall(id: "1", name: "named", arguments: "{}")
        expect(routed.title(for: named) == "named: 1", "a provider may title its own call's row")
        expect(
            routed.title(for: AIToolCall(id: "2", name: "t_read", arguments: "{}")) == nil
                && routed.title(for: AIToolCall(id: "3", name: "srv__x", arguments: "{}")) == nil
                && routed.title(for: AIToolCall(id: "4", name: "nope", arguments: "{}")) == nil,
            "every other row keeps its tool's title")
    }
}

/// Cross-turn compaction's arithmetic: what was dropped, what the notes cover, and what goes out.
extension AgentTests {
    /// `count` messages of 100 bytes, a question at every even index.
    static func history(_ count: Int) -> [AgentCompaction.Entry] {
        (0..<count).map { index in
            AgentCompaction.Entry(
                id: UUID(), isUser: index.isMultiple(of: 2),
                text: String(index % 10) + String(repeating: "m", count: 99))
        }
    }

    static func sent(_ history: [AgentCompaction.Entry], from start: Int) -> [AIMessage] {
        history[start...].map { AIMessage(role: $0.isUser ? .user : .assistant, text: $0.text) }
    }

    static func compactionCoversWhatTheBudgetDrops() {
        let chat = history(19)
        expect(AgentCompaction.dropped(from: chat, sent: sent(chat, from: 10)) == 10, "ten were dropped")
        expect(AgentCompaction.dropped(from: chat, sent: sent(chat, from: 0)) == 0, "or none")
        let shifted = sent(chat, from: 10).map {
            AIMessage(role: $0.role == .user ? .assistant : .user, text: $0.text)
        }
        expect(
            AgentCompaction.dropped(from: chat, sent: shifted) == nil,
            "a request that no longer lines up with the history is left alone")
        expect(
            AgentCompaction.dropped(from: Array(chat.prefix(3)), sent: sent(chat, from: 10)) == nil,
            "as is one longer than the history")

        expect(
            AgentCompaction.coverage(of: chat, dropped: 10) == 14,
            "notes reach the first question from which at most half of what fitted is left")
        expect(
            AgentCompaction.coverage(of: chat, dropped: 18) == 18,
            "and never past the newest question")
        var pasted = chat
        pasted[18] = AgentCompaction.Entry(
            id: chat[18].id, isUser: true, text: String(repeating: "q", count: 110_000))
        expect(
            AgentCompaction.coverage(of: pasted, dropped: 10) == 14,
            "a long pasted question goes out whole, so it never pushes the notes over what fitted")
        let first = AgentCompaction.plan(history: chat, dropped: 10, summary: nil)
        expect(first == .extend(from: 0, to: 14, previous: nil), "the first notes cover from the start")

        let notes = AgentChatSummary(text: "notes", covered: 16, lastCoveredID: chat[15].id)
        expect(
            AgentCompaction.plan(history: chat, dropped: 10, summary: notes) == .reuse(notes)
                && AgentCompaction.plan(history: chat, dropped: 16, summary: notes) == .reuse(notes),
            "notes that reach past what was dropped are reused, with no request")
        let longer = history(31)
        let moved = AgentChatSummary(text: "notes", covered: 14, lastCoveredID: longer[13].id)
        expect(
            AgentCompaction.plan(history: longer, dropped: 16, summary: moved)
                == .extend(from: 14, to: AgentCompaction.coverage(of: longer, dropped: 16), previous: moved),
            "past them, only the newly dropped messages are folded in")
        let stale = AgentChatSummary(text: "notes", covered: 14, lastCoveredID: UUID())
        expect(
            AgentCompaction.plan(history: chat, dropped: 10, summary: stale)
                == .extend(from: 0, to: 14, previous: nil),
            "notes on a history that changed underneath start over")
        let odd = AgentChatSummary(text: "notes", covered: 13, lastCoveredID: chat[12].id)
        expect(
            AgentCompaction.plan(history: chat, dropped: 10, summary: odd) == .extend(from: 0, to: 14, previous: nil),
            "as do notes that would leave a reply opening the request")
    }

    static func compactionNotesRideTheFirstQuestion() {
        let chat = history(19)
        let image = AIImage(data: Data([1]), mimeType: "image/png")
        var request = sent(chat, from: 10)
        request[request.count - 1] = AIMessage(role: .user, text: chat[18].text, images: [image])
        let notes = AgentChatSummary(text: "notes", covered: 14, lastCoveredID: chat[13].id)
        let led = AgentCompaction.messages(request, dropped: 10, summary: notes)
        expect(led.count == 5, "what the notes stand for is not sent twice")
        expect(
            led.first?.role == .user && led.first?.text == AgentCompaction.preface("notes") + chat[14].text,
            "the notes lead the first question sent, so no two questions arrive in a row")
        expect(led.last?.images == [image], "and the newest question keeps its attachments")
        let whole = AgentChatSummary(text: "notes", covered: 18, lastCoveredID: chat[17].id)
        let alone = AgentCompaction.messages(request, dropped: 10, summary: whole)
        expect(
            alone.count == 1 && alone.first?.images == [image]
                && alone.first?.text.hasPrefix(AgentCompaction.preface("notes")) == true,
            "notes may lead the newest question itself")

        let fold = AgentCompaction.request(previous: notes, slice: chat[14..<18])
        let text = fold.messages.first?.text ?? ""
        expect(
            fold.instructions == AgentCompaction.instructions && fold.tools.isEmpty
                && fold.messages.count == 1,
            "folding is one request with no tools")
        expect(
            text.hasPrefix("<notes>\nnotes\n</notes>") && text.contains("User: " + chat[14].text)
                && text.contains("Agent: " + chat[17].text) && !text.contains(chat[13].text),
            "it carries the notes so far and only the messages they must now cover")
        let huge = (0..<40).map { index in
            AgentCompaction.Entry(
                id: UUID(), isUser: index.isMultiple(of: 2), text: String(repeating: "й", count: 10_000))
        }
        let bounded = AgentCompaction.request(previous: nil, slice: huge[0..<40]).messages.first?.text ?? ""
        expect(
            bounded.utf8.count <= AgentCompaction.maxSourceBytes + 128
                && bounded.contains("earlier messages left out."),
            "a long stretch is read newest first, each message clipped, and says what it left out")
        expect(
            AgentCompaction.summary("  ", covering: 14, of: chat) == nil,
            "a model that wrote nothing leaves no notes")
        let kept = AgentCompaction.summary(String(repeating: "ж", count: 9_000), covering: 14, of: chat)
        expect(
            (kept?.text.utf8.count ?? .max) <= AgentCompaction.maxSummaryBytes + 3
                && kept?.covered == 14 && kept?.lastCoveredID == chat[13].id,
            "notes are held to 8 KB and remember the last message they stand for")
    }

    static func compactionNotesAreKeptPerChat() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentStore(directory: directory)
        let (kept, gone, freed) = (UUID(), UUID(), UUID())
        let notes = AgentChatSummary(text: "notes", covered: 2, lastCoveredID: UUID())
        for chat in [kept, gone, freed] { try? notes.write(to: store.summaryURL(forChat: chat)) }
        expect(AgentChatSummary.load(from: store.summaryURL(forChat: kept)) == notes, "notes round-trip")
        expect(
            store.summaryURL(forChat: kept).path.contains("agent-summaries/\(kept.uuidString.lowercased())"),
            "one file per chat, beside the agents")
        store.pruneSummaries(keeping: [kept, freed])
        expect(
            AgentChatSummary.load(from: store.summaryURL(forChat: gone)) == nil
                && AgentChatSummary.load(from: store.summaryURL(forChat: kept)) != nil,
            "a deleted chat's notes are swept, the rest stay")
        guard let agent = try? store.add(AgentProfile(name: "Builder", directory: folder)) else {
            return expect(false, "an agent is saved")
        }
        store.setAgent(agent.id, forChat: freed)
        try? store.remove(id: agent.id)
        expect(
            AgentChatSummary.load(from: store.summaryURL(forChat: freed)) == nil,
            "deleting an agent drops its chats' notes, since they are plain chats now")
        store.removeSummary(forChat: kept)
        expect(AgentChatSummary.load(from: store.summaryURL(forChat: kept)) == nil, "and so can one chat")
    }
}

/// Names each call's row after the call.
struct TitledProvider: AgentToolProvider {
    func specs(for turn: AgentTurn) -> [AgentToolSpec] {
        [
            AgentToolSpec(
                tool: AITool(name: "named", description: "", parameters: .object([:]), origin: "Test"),
                family: nil, risk: .read, concurrent: false)
        ]
    }

    func run(_ call: AIToolCall, in context: AgentToolContext) async -> AIToolResult {
        .failure(call.id, "fake")
    }

    func title(for call: AIToolCall) -> String? { "named: " + call.id }
}

/// Offers what it is given; its calls are never run here.
struct FakeProvider: AgentToolProvider {
    let offered: [AgentToolSpec]

    func specs(for turn: AgentTurn) -> [AgentToolSpec] { offered }

    func run(_ call: AIToolCall, in context: AgentToolContext) async -> AIToolResult {
        .failure(call.id, "fake")
    }
}

/// `read_file`, `web_fetch` and `search_files` as the model sees them, and Spotlight's query.
extension AgentTests {
    static func readingToolsDescribeTheirReach() {
        func properties(_ name: String, _ agent: AgentProfile) -> Set<String> {
            let tool = AgentToolbox.tools(for: agent, hasSkills: false).first { $0.name == name }
            return Set(tool?.parameters.objectValue?["properties"]?.objectValue?.keys.map { $0 } ?? [])
        }
        expect(
            properties(AgentToolbox.readFile, profile()) == ["path", "offset", "limit", "pages", "raw"],
            "read_file pages a PDF and reads an HTML file's source on request")
        expect(properties(AgentToolbox.webFetch, profile()) == ["url", "part", "pages"], "web_fetch pages and parts")
        expect(
            properties(AgentToolbox.searchFiles, profile())
                == ["pattern", "path", "mode", "kind", "modified_after", "names_only"],
            "search_files takes Spotlight's narrowing")
        func search(_ access: AgentAccess) -> String {
            AgentToolbox.tools(for: profile(access), hasSkills: false)
                .first { $0.name == AgentToolbox.searchFiles }?.description ?? ""
        }
        expect(search(.fullAccess).contains("in the home folder and iCloud Drive, or the path given"), "full access: home")
        expect(search(.readOnly).contains("in the agent's folder"), "anything less: its folder")
        expect(
            AgentToolbox.spec(for: tool(AgentToolbox.searchFiles)).risk == .read
                && AgentToolbox.spec(for: tool(AgentToolbox.searchFiles)).concurrent,
            "searching stays a read that may share a round")
    }

    static func spotlightQueriesAreBuiltNotWritten() {
        func parse(_ arguments: [String: JSONValue]) -> Result<AgentSpotlightQuery, AgentSpotlightQuery.Failure> {
            AgentSpotlightQuery.parse(arguments)
        }
        expect(
            AgentSpotlightQuery.terms(in: #"  tax  "annual report" 2025 "" - "#) == ["tax", "annual report", "2025"],
            "words, quoted phrases, nothing empty or without a letter or digit")
        expect(AgentSpotlightQuery.terms(in: (1...12).map(String.init).joined(separator: " ")).count == 8, "eight terms")
        let query = try? parse(["pattern": .string("tax \"annual report\"")]).get()
        expect(
            query?.query == #"(kMDItemFSName == "*tax*"cd || kMDItemTitle == "*tax*"cd || kMDItemTextContent == "tax*"cdw)"#
                + #" && (kMDItemFSName == "*annual report*"cd || kMDItemTitle == "*annual report*"cd || "#
                + #"kMDItemTextContent == "annual report*"cdw)"#,
            "each term matches a name, a title or the indexed text, got \(query?.query ?? "nothing")")
        let names = try? parse([
            "pattern": .string("invoice"), "names_only": .bool(true), "kind": .string("PDF"),
            "modified_after": .string("2026-10-01")
        ]).get()
        expect(
            names?.query == #"(kMDItemFSName == "*invoice*"cd || kMDItemTitle == "*invoice*"cd) && "#
                + #"(kMDItemContentTypeTree == "com.adobe.pdf") && kMDItemFSContentChangeDate >= $time.iso(2026-10-01)"#,
            "names only, a kind by its content type, a date, got \(names?.query ?? "nothing")")
        expect(
            AgentSpotlightQuery.terms(in: #"a"||kMDItemFSName=="*"#) == ["a", "||kMDItemFSName=="],
            "a quote only ever bounds a phrase, so none reaches the query")
        let hostile = try? parse(["pattern": .string(#"a*b c\d"#)]).get()
        expect(
            hostile?.query.contains(#"kMDItemFSName == "*a\*b*"cd"#) == true
                && hostile?.query.contains(#"kMDItemTextContent == "c\\d*"cdw"#) == true,
            "wildcards and backslashes in a word are escaped, got \(hostile?.query ?? "")")
        expect(
            AgentSpotlightQuery.escaped("a\\b?\n") == #"a\\b\?"#, "backslashes, wildcards and newlines too")
        let folders = try? parse(["pattern": .string(""), "kind": .string("folder")]).get()
        expect(folders?.query == #"(kMDItemContentTypeTree == "public.folder")"#, "a kind alone is a query")
        expect(
            parse(["pattern": .string(" ")]).failure?.message.contains("Give words") == true,
            "nothing to find is refused")
        expect(parse(["pattern": .string("x"), "kind": .string("movie")]).failure != nil, "an unknown kind")
        for date in ["2026-1-01", "2026-13-01", "26-10-01", "2026-10-01T00:00", "2026-10-01) || (x"] {
            expect(parse(["pattern": .string("x"), "modified_after": .string(date)]).failure != nil, "\(date) is no date")
        }
        expect(
            query?.arguments(in: ["/Users/me"]) == ["-onlyin", "/Users/me", query?.query ?? ""],
            "one argument for the root and one for the query, never a shell line")

        let roots = ["/Users/me"]
        expect(AgentSpotlightQuery.isShown("/Users/me/Documents/tax.pdf", roots: roots, home: "/Users/me"), "a document")
        expect(!AgentSpotlightQuery.isShown("/Users/me/.ssh/id_ed25519", roots: roots, home: "/Users/me"), "no hidden path")
        expect(!AgentSpotlightQuery.isShown("/Users/me/a/.git/HEAD", roots: roots, home: "/Users/me"), "at any depth")
        expect(
            !AgentSpotlightQuery.isShown("/Users/me/Library/Mail/V10/x.emlx", roots: roots, home: "/Users/me"),
            "nor mail, messages or caches under Library")
        expect(
            AgentSpotlightQuery.isShown(
                "/Users/me/Library/Mobile Documents/x.pdf", roots: ["/Users/me/Library/Mobile Documents"],
                home: "/Users/me"),
            "unless the search began there")
        expect(!AgentSpotlightQuery.isShown("/Volumes/x/a.pdf", roots: roots, home: "/Users/me"), "nothing past the root")
        let drive = "/Users/me/Library/Mobile Documents/"
        expect(
            AgentSpotlightQuery.isShown(drive + "com~apple~CloudDocs/Taxes/invoice.pdf", roots: roots, home: "/Users/me")
                && AgentSpotlightQuery.isShown(drive + "com~apple~Pages/Documents/Plan.pages", roots: roots, home: "/Users/me")
                && AgentSpotlightQuery.isShown(
                    "/Users/me/Library/CloudStorage/Dropbox/a.pdf", roots: roots, home: "/Users/me"),
            "iCloud Drive, an app's iCloud Documents and cloud folders are the user's documents")
        expect(
            !AgentSpotlightQuery.isShown(drive + "iCloud~md~obsidian/Data/cache.db", roots: roots, home: "/Users/me")
                && !AgentSpotlightQuery.isShown(drive + "com~apple~CloudDocs/.Trash/a.pdf", roots: roots, home: "/Users/me"),
            "but not an app's own iCloud data, nor a hidden path in them")
        expect(
            AgentSpotlightQuery.terms(in: "a\u{0}b \u{7}\u{1B}c") == ["ab", "c"]
                && AgentSpotlightQuery.escaped("x\u{0}y\u{1F}") == "xy",
            "a NUL or other control character never reaches mdfind, whose launch it would end")

        let day: TimeInterval = 86_400
        let hits = [
            AgentSpotlightQuery.Hit(
                path: "/Users/me/old.pdf", isFolder: false, size: 2_048, modified: Date(timeIntervalSince1970: 0)),
            AgentSpotlightQuery.Hit(
                path: "/Users/me/new.pdf", isFolder: false, size: 3_500_000,
                modified: Date(timeIntervalSince1970: 20_000 * day)),
            AgentSpotlightQuery.Hit(path: "/Users/me/Taxes", isFolder: true, size: nil, modified: nil)
        ]
        let listing = AgentSpotlightQuery.listing(hits, matched: 3, cut: false, timeZone: TimeZone(identifier: "UTC")!)
        expect(
            listing == "2024-10-04  3.3 MB    /Users/me/new.pdf\n1970-01-01  2 KB      /Users/me/old.pdf\n"
                + "            folder    /Users/Me/Taxes".replacingOccurrences(of: "Me", with: "me"),
            "newest first, with its date and size, got:\n\(listing)")
        let many = (0..<60).map {
            AgentSpotlightQuery.Hit(
                path: "/Users/me/\($0)", isFolder: false, size: 1, modified: Date(timeIntervalSince1970: Double($0)))
        }
        let long = AgentSpotlightQuery.listing(many, matched: 80, cut: false, timeZone: .current)
        expect(long.split(separator: "\n").count == 51 && long.hasSuffix("30 more matched; narrow the words, kind, "
            + "modified_after or path."), "fifty shown, the rest counted")
        expect(
            AgentSpotlightQuery.listing([], matched: 0, cut: false, timeZone: .current).hasPrefix("Spotlight found nothing"),
            "nothing found points at mode text")
    }
}

extension Result {
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}
