import Foundation

/// Skill discovery over real folders, the per-agent selection, its persistence and the prompt.
@main
@MainActor
struct AgentSkillsTests {
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
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-skills-test-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let home = (base as NSString).appendingPathComponent("home")
        let folder = (base as NSString).appendingPathComponent("project")
        layOut(home: home, folder: folder)

        rootsKeepTheirPrecedence()
        discoveryPrefersTheProjectThenTheSharedFolders(home: home, folder: folder)
        sourcesSwitchTheirFoldersOff(home: home, folder: folder)
        anAgentInTheHomeFolderReadsItsSkillsOnce(home: home)
        theSelectionDecidesTheCatalog()
        theSelectionSurvivesASave()
        olderAndOddFilesLoadAsAll()
        thePromptHonoursTheSelection(home: home, folder: folder)

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Folders

    static func write(_ name: String, description: String, in root: String, group: String? = nil) {
        let parent = group.map { (root as NSString).appendingPathComponent($0) } ?? root
        let folder = (parent as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let manifest = "---\nname: \(name)\ndescription: \(description)\n---\n\n# \(name)\n"
        try? manifest.write(
            toFile: (folder as NSString).appendingPathComponent("SKILL.md"), atomically: true,
            encoding: .utf8)
    }

    static func layOut(home: String, folder: String) {
        let project = (folder as NSString).appendingPathComponent(".agents/skills")
        let shared = (home as NSString).appendingPathComponent(".agents/skills")
        let config = (home as NSString).appendingPathComponent(".config/agents/skills")
        let claude = (home as NSString).appendingPathComponent(".claude/skills")
        write("deploy", description: "project", in: project)
        write("deploy", description: "shared", in: shared)
        write("review", description: "shared", in: shared)
        write("review", description: "config", in: config)
        write("translate", description: "config", in: config)
        write("translate", description: "claude", in: claude)
        write("pdf", description: "claude", in: claude, group: "documents")
        write("notes", description: "claude", in: claude)
    }

    static func rootsKeepTheirPrecedence() {
        let roots = AgentSkillRoot.ordered(
            folder: "/p", home: "/h", sources: Set(AgentSkillSource.allCases))
        expect(
            roots.map(\.path)
                == ["/p/.agents/skills", "/h/.agents/skills", "/h/.config/agents/skills", "/h/.claude/skills"],
            "the project's folder first, then ~/.agents, ~/.config/agents and ~/.claude")
        expect(
            roots.map(\.source) == [.project, .global, .global, .global],
            "the three home folders are all the global source")
        expect(
            AgentSkillRoot.ordered(folder: "/p", home: "/h", sources: [.global]).count == 3,
            "the project switch off leaves only the home folders")
    }

    static func discoveryPrefersTheProjectThenTheSharedFolders(home: String, folder: String) {
        let found = AgentContextLoader.skills(in: folder, home: home)
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })
        expect(
            found.map(\.name) == ["deploy", "notes", "pdf", "review", "translate"],
            "one skill per name across four folders, sorted")
        expect(byName["deploy"]?.description == "project", "the project's skill shadows ~/.agents'")
        expect(byName["deploy"]?.source == .project, "and keeps the project source")
        expect(byName["review"]?.description == "shared", "~/.agents shadows ~/.config/agents")
        expect(byName["translate"]?.description == "config", "~/.config/agents shadows ~/.claude")
        expect(byName["notes"]?.source == .global, "a skill only Claude's folder has is global")
        expect(
            byName["pdf"]?.directory.hasSuffix(".claude/skills/documents/pdf") == true,
            "a group folder's skills are found one level down")
        expect(
            byName["review"]?.root == (home as NSString).appendingPathComponent(".agents/skills"),
            "a skill names the folder it was found in")
        expect(
            byName["pdf"]?.root == (home as NSString).appendingPathComponent(".claude/skills"),
            "a grouped skill names its skills folder, not the group")
    }

    static func sourcesSwitchTheirFoldersOff(home: String, folder: String) {
        let global = AgentContextLoader.skills(in: folder, sources: [.global], home: home)
        expect(
            global.first { $0.name == "deploy" }?.description == "shared",
            "with project skills off, the shared folder's copy is the one offered")
        let project = AgentContextLoader.skills(in: folder, sources: [.project], home: home)
        expect(project.map(\.name) == ["deploy"], "with global skills off, only the folder's own")
        expect(
            AgentContextLoader.skills(in: folder, sources: [], home: home).isEmpty,
            "both off read nothing")
    }

    static func anAgentInTheHomeFolderReadsItsSkillsOnce(home: String) {
        let found = AgentContextLoader.skills(in: home, home: home)
        expect(
            found.first { $0.name == "review" }?.source == .project,
            "an agent living in the home folder reads ~/.agents/skills as its own")
        expect(Set(found.map(\.name)).count == found.count, "and lists each name once")
    }

    // MARK: - Selection

    static let skills = [
        AgentSkill(name: "deploy", description: "", directory: "/p/deploy", source: .project),
        AgentSkill(name: "review", description: "", directory: "/g/review", source: .global),
        AgentSkill(name: "write", description: "", directory: "/g/write", source: .global)
    ]

    static func theSelectionDecidesTheCatalog() {
        expect(
            AgentSkill.catalog(skills, disabled: [], selection: nil).map(\.name)
                == ["deploy", "review", "write"],
            "no selection is All, every skill found")
        expect(
            AgentSkill.catalog(skills, disabled: ["review"], selection: nil).map(\.name)
                == ["deploy", "write"],
            "All still leaves a switched-off skill out")
        let picked = AgentSkillSelection(mode: .selected, names: ["write", "gone"])
        expect(
            AgentSkill.catalog(skills, disabled: [], selection: picked).map(\.name) == ["write"],
            "Only Selected offers just the names picked that still exist")
        expect(
            AgentSkill.catalog(skills, disabled: ["write"], selection: picked).map(\.name) == ["write"],
            "Only Selected reads its own names, not All's switched-off list")
        let kept = AgentSkillSelection(mode: .all, names: ["write"])
        expect(
            AgentSkill.catalog(skills, disabled: [], selection: kept).count == 3,
            "names kept while back on All do not narrow it")
        expect(
            AgentSkill.catalog(skills, disabled: [], selection: AgentSkillSelection(mode: .selected))
                .isEmpty,
            "Only Selected with nothing picked offers nothing")
    }

    static func profile(selection: AgentSkillSelection?) -> AgentProfile {
        var profile = AgentProfile(name: "Builder", directory: "/p", disabledSkills: ["review"])
        profile.skillSelection = selection
        return profile
    }

    static func json(_ profile: AgentProfile) -> [String: Any] {
        let data = (try? JSONEncoder().encode(profile)) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func decode(_ object: [String: Any]) -> AgentProfile? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(AgentProfile.self, from: data)
    }

    static func theSelectionSurvivesASave() {
        let picked = profile(selection: AgentSkillSelection(mode: .selected, names: ["write", "deploy"]))
        let object = json(picked)
        let stored = object["skillSelection"] as? [String: Any]
        expect(stored?["mode"] as? String == "selected", "the mode is written by name")
        expect(stored?["names"] as? [String] == ["deploy", "write"], "names are written sorted")
        expect(decode(object) == picked, "Only Selected and its names read back as saved")
        expect(json(profile(selection: nil))["skillSelection"] == nil, "All with no names writes nothing")
    }

    static func olderAndOddFilesLoadAsAll() {
        var older = json(profile(selection: nil))
        older["skillSelection"] = nil
        let read = decode(older)
        expect(read != nil, "an agent saved before the selection still loads")
        expect(read?.skillSelection == nil, "and offers all its skills")
        expect(read?.disabledSkills == ["review"], "keeping what it had switched off")

        older["skillSelection"] = ["mode": "favourites", "names": ["write"]]
        expect(
            decode(older)?.skillSelection?.mode == .all,
            "a mode a newer build wrote reads as All")
        older["skillSelection"] = ["mode": "selected"]
        expect(
            decode(older)?.skillSelection == AgentSkillSelection(mode: .selected),
            "a selection without names picks none")
        older["skillSelection"] = "selected"
        let odd = decode(older)
        expect(odd != nil, "a selection that does not read never costs the agent")
        expect(odd?.skillSelection == nil, "and leaves it on All")
        older["skillSelection"] = ["mode": 3, "names": "write"]
        expect(decode(older)?.skillSelection == AgentSkillSelection(), "wrong types read as empty All")
    }

    // MARK: - Prompt

    static func thePromptHonoursTheSelection(home: String, folder: String) {
        let memory = URL(fileURLWithPath: (home as NSString).appendingPathComponent("no-notes.md"))
        var agent = AgentProfile(name: "Builder", directory: folder, disabledSkills: ["notes"])
        let all = AgentContextLoader.load(agent, memoryURL: memory, home: home)
        expect(
            all.skills.map(\.name) == ["deploy", "pdf", "review", "translate"],
            "All loads every folder's skills but the one switched off")

        agent.skillSelection = AgentSkillSelection(mode: .selected, names: ["notes", "translate"])
        let context = AgentContextLoader.load(agent, memoryURL: memory, home: home)
        expect(context.skills.map(\.name) == ["notes", "translate"], "Only Selected loads just its picks")
        let prompt = context.prompt(now: Date(), timeZone: .current, hasTools: true)
        expect(prompt.contains("- notes: claude"), "the prompt lists a picked skill")
        expect(prompt.contains("- translate: config"), "with the copy that won its name")
        expect(!prompt.contains("- deploy:"), "and leaves an unpicked one out")
        let briefing = context.briefing()
        expect(briefing.contains("notes: claude"), "an ACP briefing lists the picks too")
        expect(!briefing.contains("deploy"), "and nothing else")

        agent.skillSelection = AgentSkillSelection(mode: .selected)
        let none = AgentContextLoader.load(agent, memoryURL: memory, home: home)
        expect(
            !none.prompt(now: Date(), timeZone: .current, hasTools: true).contains("## Skills"),
            "with nothing picked the prompt has no Skills section")
        let offered = { (skills: [AgentSkill]) in
            AgentToolbox.tools(for: agent, hasSkills: !skills.isEmpty).map(\.name)
        }
        expect(!offered(none.skills).contains(AgentToolbox.loadSkill), "and load_skill is not offered")
        expect(offered(context.skills).contains(AgentToolbox.loadSkill), "a pick brings load_skill back")
    }
}
