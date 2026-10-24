import Foundation

/// A folder skills are read from, with the source switch that governs it.
struct AgentSkillRoot: Equatable, Sendable {
    let path: String
    let source: AgentSkillSource

    /// Highest precedence first: the folder's own, then the shared home folder, then Claude's.
    static func ordered(folder: String, home: String, sources: Set<AgentSkillSource>) -> [Self] {
        let project = [Self(path: join(folder, ".agents/skills"), source: .project)]
        let global = [".agents/skills", ".config/agents/skills", ".claude/skills"].map {
            Self(path: join(home, $0), source: .global)
        }
        var seen: Set<String> = []
        // An agent living in the home folder would otherwise read ~/.agents/skills twice.
        return (project + global).filter { sources.contains($0.source) && seen.insert($0.path).inserted }
    }

    private static func join(_ base: String, _ relative: String) -> String {
        (base as NSString).appendingPathComponent(relative)
    }
}
