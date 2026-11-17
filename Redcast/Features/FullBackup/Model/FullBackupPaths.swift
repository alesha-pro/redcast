import Foundation

/// A path under the home folder travels as `~/…`: no `/Users/<name>` enters a file people share.
enum FullBackupPaths {
    static func portable(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func local(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == "~" { return home }
        return path.hasPrefix("~/") ? home + path.dropFirst() : path
    }

    static func agent(_ agent: AgentProfile, _ transform: (String) -> String) -> AgentProfile {
        var agent = agent
        agent.directory = transform(agent.directory)
        if var runtime = agent.runtime {
            runtime.command = transform(runtime.command)
            runtime.arguments = runtime.arguments.map(transform)
            agent.runtime = runtime
        }
        return agent
    }

    static func server(_ server: MCPServer, _ transform: (String) -> String) -> MCPServer {
        guard case .stdio(let command, let arguments, let keys) = server.transport else { return server }
        var server = server
        server.transport = .stdio(
            command: transform(command), arguments: arguments.map(transform), environmentKeys: keys)
        return server
    }

    static func override(
        _ override: InstalledAIOverride, _ transform: (String) -> String
    ) -> InstalledAIOverride {
        var override = override
        override.commandPath = transform(override.commandPath)
        return override
    }

    static func value(_ value: FullBackupValue, _ transform: (String) -> String) -> FullBackupValue {
        switch value {
        case .string(let text): return .string(transform(text))
        case .application(let path): return .application(transform(path))
        case .number, .bool: return value
        }
    }
}
