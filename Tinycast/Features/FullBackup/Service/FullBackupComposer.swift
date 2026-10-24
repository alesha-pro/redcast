import Foundation

/// Stores → `full/`: `plan` reads on the main actor, `write` does the IO and the sealing off it.
@MainActor
enum FullBackupComposer {
    struct Part: Sendable {
        var data: Data
        var count: Int
    }

    struct Plan: Sendable {
        var parts: [FullBackupSection: Part] = [:]
        var chatDatabase: URL?
        var chatSummaries: URL?
        var secrets: Data?
        var secretsCount = 0
        var passphrase: String?

        var isEmpty: Bool { parts.isEmpty && secrets == nil }
    }

    static func plan(
        _ sections: Set<FullBackupSection>, passphrase: String?, from core: AppCore
    ) -> Plan {
        var plan = Plan()
        func add(_ section: FullBackupSection, _ payload: some Encodable, count: Int) {
            guard let data = try? FullBackupLayout.encoder.encode(payload) else { return }
            plan.parts[section] = Part(data: data, count: count)
        }
        if sections.contains(.agents) {
            let payload = FullBackupGather.agents(from: core)
            add(.agents, payload, count: payload.count)
        }
        if sections.contains(.mcpServers) {
            let payload = FullBackupGather.mcp(from: core)
            add(.mcpServers, payload, count: payload.count)
        }
        if sections.contains(.ai) {
            let payload = FullBackupGather.ai(from: core)
            add(.ai, payload, count: payload.count)
        }
        if sections.contains(.voice) {
            let payload = FullBackupGather.voice(from: core)
            add(.voice, payload, count: payload.count)
        }
        if sections.contains(.quickActions) {
            let payload = FullBackupGather.quickActions(from: core)
            add(.quickActions, payload, count: payload.count)
        }
        let needsExtensions = sections.contains(.extensions) || passphrase != nil
        let extensions = needsExtensions ? FullBackupGather.extensions(from: core) : nil
        if sections.contains(.extensions), let payload = extensions?.payload {
            add(.extensions, payload, count: payload.count)
        }
        if sections.contains(.more) {
            let payload = FullBackupGather.more(from: core)
            add(.more, payload, count: payload.count)
        }
        if sections.contains(.chatHistory) {
            let payload = FullBackupGather.chatHistory(from: core)
            add(.chatHistory, payload, count: payload.count)
            plan.chatDatabase = core.chatHistory.databaseURL
            plan.chatSummaries = core.agentStore.directory.appendingPathComponent(
                "agent-summaries", isDirectory: true)
        }
        if let passphrase {
            let secrets = FullBackupGather.secrets(from: core, extensions: extensions?.secrets ?? [:])
            plan.secrets = try? FullBackupLayout.encoder.encode(secrets)
            plan.secretsCount = secrets.count
            plan.passphrase = passphrase
        }
        return plan
    }

    nonisolated static func write(_ plan: Plan, into layout: FullBackupLayout) throws -> FullBackupContents {
        var contents = FullBackupContents()
        guard !plan.isEmpty else { return contents }
        try layout.prepare()
        for (section, part) in plan.parts {
            try part.data.write(to: layout.payloadURL(section), options: .atomic)
            contents.sections[section.rawValue] = .init(version: section.version, count: part.count)
        }
        if let database = plan.chatDatabase {
            try FileManager.default.createDirectory(
                at: layout.chatSummariesDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: database.path) {
                try FullBackupChatArchive.snapshot(database, to: layout.chatDatabaseURL)
            }
            try copySummaries(from: plan.chatSummaries, to: layout.chatSummariesDirectory)
        }
        if let secrets = plan.secrets, let passphrase = plan.passphrase {
            let sealed = try FullBackupCipher.seal(secrets, passphrase: passphrase, count: plan.secretsCount)
            try layout.writeSecrets(sealed.sealed)
            contents.secrets = sealed.header
        }
        try layout.writeContents(contents)
        return contents
    }

    private nonisolated static func copySummaries(from source: URL?, to destination: URL) throws {
        guard let source else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            try FileManager.default.copyItem(
                at: source.appendingPathComponent(name).resolvingSymlinksInPath(),
                to: destination.appendingPathComponent(name))
        }
    }
}
