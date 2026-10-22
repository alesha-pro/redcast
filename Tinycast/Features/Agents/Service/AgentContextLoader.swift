import Foundation

/// Reads an agent's folder for what its turns are told: instructions files, skills and notes.
nonisolated enum AgentContextLoader {
    /// `AGENTS.md` is the shared convention; `CLAUDE.md` is read only where it stands alone.
    private static let projectInstructionNames = ["AGENTS.md", "CLAUDE.md"]

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static func load(_ profile: AgentProfile, memoryURL: URL) -> AgentContext {
        let project =
            profile.readsProjectInstructions
            ? projectInstructionNames.lazy.compactMap {
                instructions(at: (profile.directory as NSString).appendingPathComponent($0))
            }.first : nil
        let global =
            profile.readsGlobalInstructions
            ? instructions(at: (home as NSString).appendingPathComponent(".agents/AGENTS.md")) : nil
        let found = skills(in: profile.directory, sources: profile.skillSources)
        let memory = (try? String(contentsOf: memoryURL, encoding: .utf8))
        return AgentContext(
            profile: profile, projectInstructions: project, globalInstructions: global,
            skills: AgentSkill.catalog(
                project: found.project, global: found.global, disabled: profile.disabledSkills),
            memory: memory)
    }

    /// Both sources whether enabled or not, so the editor can list what a switch would add.
    static func skills(
        in directory: String, sources: Set<AgentSkillSource> = Set(AgentSkillSource.allCases)
    ) -> (project: [AgentSkill], global: [AgentSkill]) {
        let project =
            sources.contains(.project)
            ? scan((directory as NSString).appendingPathComponent(".agents/skills"), as: .project)
            : []
        let global =
            sources.contains(.global)
            ? scan((home as NSString).appendingPathComponent(".agents/skills"), as: .global) : []
        return (project, global)
    }

    private static func instructions(at path: String) -> AgentContext.Instructions? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return AgentContext.Instructions(path: path, text: text)
    }

    /// A folder with no `SKILL.md` of its own is a group, and its children are looked at once.
    private static func scan(_ root: String, as source: AgentSkillSource) -> [AgentSkill] {
        var found: [AgentSkill] = []
        for folder in subfolders(of: root) {
            if let skill = skill(in: folder, as: source) {
                found.append(skill)
                continue
            }
            found += subfolders(of: folder).compactMap { skill(in: $0, as: source) }
        }
        return found
    }

    private static func skill(in folder: String, as source: AgentSkillSource) -> AgentSkill? {
        let manifest = (folder as NSString).appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOfFile: manifest, encoding: .utf8) else { return nil }
        return AgentSkill.parse(manifest: text, directory: folder, source: source)
    }

    private static func subfolders(of path: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { name in
            let child = (path as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { return nil }
            return child
        }
    }
}
