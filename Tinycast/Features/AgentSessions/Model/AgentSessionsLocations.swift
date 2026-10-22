import Foundation

/// Where each agent keeps its history on this Mac; Claude Code's and Codex's folders can be moved.
struct AgentSessionsLocations: Equatable, Sendable {
    let home: URL
    /// `CLAUDE_CONFIG_DIR` when the person named a folder, else `~/.claude`.
    let claude: URL
    /// `CODEX_HOME` when the person named a folder, else `~/.codex`.
    let codex: URL

    /// Empty, relative or default text reads the default folder.
    init(home: URL, claudeFolder: String = "", codexFolder: String = "") {
        self.home = home
        claude = Self.folder(claudeFolder, home: home) ?? Self.defaultClaude(home)
        codex = Self.folder(codexFolder, home: home) ?? Self.defaultCodex(home)
    }

    static func defaultClaude(_ home: URL) -> URL {
        home.appending(path: ".claude", directoryHint: .isDirectory)
    }
    static func defaultCodex(_ home: URL) -> URL {
        home.appending(path: ".codex", directoryHint: .isDirectory)
    }

    /// An absolute path or one under `~`; nil for anything else, which then reads the default.
    static func folder(_ text: String, home: URL) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if trimmed == "~" || trimmed.hasPrefix("~/") {
            path = home.path + trimmed.dropFirst()
        } else if trimmed.hasPrefix("/") {
            path = trimmed
        } else {
            return nil
        }
        return URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
    }

    var claudeProjects: URL { claude.appending(path: "projects", directoryHint: .isDirectory) }
    var codexState: URL { codex.appending(path: "state_5.sqlite", directoryHint: .notDirectory) }
    var codexHistory: URL { codex.appending(path: "thread_history_1.sqlite", directoryHint: .notDirectory) }

    func hookFile(_ target: AgentHookTarget) -> URL {
        (target == .claude ? claude : codex).appending(path: target.fileName, directoryHint: .notDirectory)
    }

    /// What a resume command or the live probe sets so the CLI reads the moved folder.
    func environment(for source: AgentSource) -> [String: String] {
        switch source {
        case .claude where !Self.same(claude, Self.defaultClaude(home)): ["CLAUDE_CONFIG_DIR": claude.path]
        case .codex where !Self.same(codex, Self.defaultCodex(home)): ["CODEX_HOME": codex.path]
        default: [:]
        }
    }

    private static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }
}
