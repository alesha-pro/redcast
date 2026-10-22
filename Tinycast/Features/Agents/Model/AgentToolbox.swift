import Foundation

/// Which paths an agent may touch; symlinks are the service's to resolve before asking.
enum AgentPathPolicy {
    enum Verdict: Equatable, Sendable {
        case allowed(String)
        case refused(String)
    }

    /// Absolute and standardized: `~` is home, anything relative hangs off the agent's folder.
    static func resolve(_ raw: String, in directory: String, home: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded: String
        if trimmed == "~" {
            expanded = home
        } else if trimmed.hasPrefix("~/") {
            expanded = (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
        } else if trimmed.hasPrefix("/") {
            expanded = trimmed
        } else {
            expanded = (directory as NSString).appendingPathComponent(trimmed)
        }
        return (expanded as NSString).standardizingPath
    }

    static func isInside(_ path: String, root: String) -> Bool {
        let root = (root as NSString).standardizingPath
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Reading reaches the folder and the skills it was given; full access reaches everything.
    static func readable(
        _ path: String, profile: AgentProfile, extraRoots: [String]
    ) -> Verdict {
        if profile.access == .fullAccess { return .allowed(path) }
        let roots = [profile.directory] + extraRoots
        guard roots.contains(where: { isInside(path, root: $0) }) else {
            return .refused("\(path) is outside \(profile.directory), which is all this agent may read.")
        }
        return .allowed(path)
    }

    static func writable(_ path: String, profile: AgentProfile) -> Verdict {
        switch profile.access {
        case .readOnly:
            return .refused("This agent is read-only and cannot change files.")
        case .workspaceWrite:
            guard isInside(path, root: profile.directory) else {
                return .refused("\(path) is outside \(profile.directory), the only folder it may change.")
            }
            return .allowed(path)
        case .fullAccess:
            return .allowed(path)
        }
    }
}

/// The built-in tools as the model sees them: names, descriptions and argument schemas.
enum AgentToolbox {
    static let listDirectory = "list_dir"
    static let readFile = "read_file"
    static let searchFiles = "search_files"
    static let writeFile = "write_file"
    static let editFile = "edit_file"
    static let runCommand = "run_command"
    static let webFetch = "web_fetch"
    static let readMemory = "memory_read"
    static let writeMemory = "memory_write"
    static let loadSkill = "load_skill"

    static func tools(for profile: AgentProfile, hasSkills: Bool) -> [AITool] {
        var tools: [AITool] = []
        let origin = profile.name
        func tool(_ name: String, _ description: String, _ properties: [String: JSONValue],
                  required: [String]) {
            tools.append(
                AITool(
                    name: name, description: description,
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object(properties),
                        "required": .array(required.map(JSONValue.string))
                    ]),
                    origin: origin, title: name))
        }
        let path = string("Path, absolute or relative to the agent's folder.")
        if profile.tools.contains(.files) {
            tool(listDirectory, "List a folder's entries; folders end with /.", ["path": path],
                 required: [])
            tool(
                readFile,
                "Read a text file with line numbers. Use offset and limit to page through a long one.",
                ["path": path, "offset": integer("First line, from 1."),
                 "limit": integer("How many lines, at most 2000.")],
                required: ["path"])
            tool(
                searchFiles, "Search file contents for a regular expression, like ripgrep.",
                ["pattern": string("Regular expression."), "path": path], required: ["pattern"])
            if profile.access.writes {
                tool(
                    writeFile, "Create or overwrite a text file with the given content.",
                    ["path": path, "content": string("The whole new content.")],
                    required: ["path", "content"])
                tool(
                    editFile,
                    "Replace one exact, unique passage of a text file with new text.",
                    ["path": path, "old_text": string("Text to find; must occur exactly once."),
                     "new_text": string("Replacement.")],
                    required: ["path", "old_text", "new_text"])
            }
        }
        if profile.tools.contains(.terminal), profile.access.writes {
            tool(
                runCommand,
                "Run a shell command (zsh, the user's environment) in the agent's folder. "
                    + "Returns its output and exit status.",
                ["command": string("The command line."),
                 "timeout_seconds": integer("Stop after this long; default 120, at most 600.")],
                required: ["command"])
        }
        if profile.tools.contains(.web) {
            tool(
                webFetch, "Fetch a web page or text URL and return its readable text.",
                ["url": string("An http or https URL.")], required: ["url"])
        }
        if profile.tools.contains(.memory) {
            tool(readMemory, "Read the notes you keep across chats.", [:], required: [])
            tool(
                writeMemory,
                "Save notes for future chats. Append by default; replace rewrites them all.",
                ["text": string("What to remember."),
                 "replace": .object(["type": .string("boolean")])],
                required: ["text"])
        }
        if hasSkills {
            tool(
                loadSkill, "Load a skill's full instructions and list its files.",
                ["name": string("The skill's name from the list in your instructions.")],
                required: ["name"])
        }
        return tools
    }

    /// What each built-in tool reaches; a name missing here is treated as the riskiest kind.
    static func spec(for tool: AITool) -> AgentToolSpec {
        switch tool.name {
        case listDirectory, readFile, searchFiles:
            AgentToolSpec(tool: tool, family: .files, risk: .read, concurrent: true)
        case writeFile, editFile: AgentToolSpec(tool: tool, family: .files, risk: .change, concurrent: false)
        case runCommand: AgentToolSpec(tool: tool, family: .terminal, risk: .execute, concurrent: false)
        case webFetch: AgentToolSpec(tool: tool, family: .web, risk: .network, concurrent: true)
        case readMemory: AgentToolSpec(tool: tool, family: .memory, risk: .read, concurrent: true)
        // Two appends in one batch would race on memory.md.
        case writeMemory: AgentToolSpec(tool: tool, family: .memory, risk: .own, concurrent: false)
        case loadSkill: AgentToolSpec(tool: tool, family: nil, risk: .read, concurrent: true)
        default: AgentToolSpec(tool: tool, family: nil, risk: .execute, concurrent: false)
        }
    }

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}
