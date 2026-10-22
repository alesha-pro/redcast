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
        thePromptCarriesTheFoldersContext()
        agentsAndTheirChatsSurviveARelaunch()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static let folder = "/Users/me/dev/project"
    static let home = "/Users/me"

    static func profile(_ access: AgentAccess = .workspaceWrite) -> AgentProfile {
        AgentProfile(name: "Builder", directory: folder, access: access)
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
        expect(full.isSubset(of: AgentToolbox.allNames), "every offered name is one the router knows")
        expect(
            AgentToolbox.tools(for: profile(), hasSkills: false).allSatisfy {
                !$0.name.contains("__")
            },
            "no built-in name can be mistaken for an MCP server's tool")
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
