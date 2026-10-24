import Foundation

/// What an import may not switch on: everything that runs code or reaches out lands off or paused.
enum FullBackupImportPolicy {
    /// Imported schedules land off; one this Mac already runs keeps running, as consented here.
    static func pausing(
        _ schedules: [AgentSchedule], runningHere: Set<UUID> = []
    ) -> (schedules: [AgentSchedule], paused: [String]) {
        let paused = schedules.filter { $0.isEnabled && !runningHere.contains($0.id) }.map(\.name)
        let landed = schedules.map { schedule in
            var schedule = schedule
            schedule.isEnabled = runningHere.contains(schedule.id)
            return schedule
        }
        return (landed, paused)
    }

    /// Imported servers land off: a stdio one launches its command, an http one receives chats.
    static func disabling(
        _ servers: [MCPServer], enabledHere: Set<UUID> = []
    ) -> (servers: [MCPServer], disabled: [String]) {
        let disabled = servers.filter { $0.isEnabled && !enabledHere.contains($0.id) }.map(\.title)
        let landed = servers.map { server in
            var server = server
            server.isEnabled = enabledHere.contains(server.id)
            return server
        }
        return (landed, disabled)
    }

    /// The commands a file can make this Mac launch later, shown before anything is applied.
    static func launches(
        agents: AgentsBackup?, mcp: MCPBackup?, ai: AIBackup?
    ) -> [String] {
        var commands: [String] = []
        for agent in agents?.agents?.items ?? [] {
            guard let runtime = agent.runtime else { continue }
            let line = ([runtime.command] + runtime.arguments).joined(separator: " ")
            commands.append("\(agent.name): \(line)")
        }
        for server in mcp?.servers?.items ?? [] {
            guard case .stdio = server.transport else { continue }
            commands.append("\(server.title): \(server.transport.summary)")
        }
        for (kind, override) in (ai?.installedOverrides ?? [:]).sorted(by: { $0.key < $1.key })
        where !override.commandPath.isEmpty {
            commands.append("\(kind): \(override.commandPath)")
        }
        return commands
    }

    /// A level that sends more of the screen than this Mac allows today is kept for the summary.
    static func appContext(
        recorded: VoiceAppContext.Level, current: VoiceAppContext.Level
    ) -> (level: VoiceAppContext.Level, widened: Bool) {
        let order = VoiceAppContext.Level.allCases
        let widens = order.firstIndex(of: recorded) ?? 0 > order.firstIndex(of: current) ?? 0
        return widens ? (current, true) : (recorded, false)
    }

    /// Commands that refresh on their own or draw in the menu bar stay off.
    static func backgroundCommands(_ items: [ExtensionsBackup.Item]) -> [String] {
        items.flatMap { item in
            Set((item.backgroundCommands ?? []) + (item.menuBarCommands ?? [])).sorted()
                .map { "\(item.title) › \($0)" }
        }
    }

    /// A fallback can only be switched off: an import must never arm Run Shell Command.
    static func disabledFallbacks(recorded: [String], current: Set<String>) -> [String] {
        current.union(recorded).sorted()
    }

    /// Recorded as on, and still off here: these are what the summary asks the reader to turn on.
    static func consentsToReview(
        _ recorded: [FullBackupConsents?], isOn: (FullBackupConsent) -> Bool
    ) -> [FullBackupConsent] {
        let on = Set(recorded.flatMap { $0?.on ?? [] })
        return FullBackupConsent.allCases.filter { on.contains($0) && !isOn($0) }
    }
}

/// Merge keeps what this Mac has and lets the file win by id; Replace also drops what it lacks.
enum FullBackupMerge {
    struct Plan<Item: Identifiable> {
        var upserts: [Item]
        var removals: [Item.ID]
    }

    static func plan<Item: Identifiable>(
        incoming: [Item], existing: [Item], mode: FullBackupImportMode
    ) -> Plan<Item> {
        guard mode == .replace else { return Plan(upserts: incoming, removals: []) }
        let kept = Set(incoming.map(\.id))
        return Plan(upserts: incoming, removals: existing.map(\.id).filter { !kept.contains($0) })
    }
}
