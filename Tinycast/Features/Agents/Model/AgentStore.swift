import Foundation
import Observation

/// Agents and which chat talks to which, as two JSON files beside the app's other authored data.
@MainActor
@Observable
final class AgentStore {
    private(set) var agents: [AgentProfile] = []
    /// Chat id to agent id; kept here rather than in chat history, which is upstream's schema.
    private(set) var chatAgents: [UUID: UUID] = [:]
    /// Chat id to the ACP session its agent keeps, so a relaunch can reload instead of restart.
    private(set) var acpSessions: [UUID: String] = [:]
    /// False when the file wouldn't read; every mutation then refuses rather than pretends.
    private(set) var isAvailable = true

    private let agentsURL: URL
    private let bindingsURL: URL
    private let acpSessionsURL: URL
    let directory: URL

    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory
        self.directory = base
        agentsURL = base.appendingPathComponent("agents.json")
        bindingsURL = base.appendingPathComponent("agent-chats.json")
        acpSessionsURL = base.appendingPathComponent("agent-acp-sessions.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private static var defaultDirectory: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tinycast.app"
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    /// Where one agent keeps what it writes down for later chats.
    func memoryURL(for id: UUID) -> URL {
        directory.appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("memory.md")
    }

    func load() {
        if FileManager.default.fileExists(atPath: agentsURL.path) {
            // A file that exists but won't read is authored data: report, never write over it.
            guard let data = try? Data(contentsOf: agentsURL),
                let decoded = try? JSONDecoder().decode([AgentProfile].self, from: data)
            else {
                isAvailable = false
                return
            }
            agents = decoded.sorted { $0.createdAt < $1.createdAt }
        }
        if let data = try? Data(contentsOf: bindingsURL),
            let decoded = try? JSONDecoder().decode([UUID: UUID].self, from: data)
        {
            let known = Set(agents.map(\.id))
            chatAgents = decoded.filter { known.contains($0.value) }
        }
        if let data = try? Data(contentsOf: acpSessionsURL),
            let decoded = try? JSONDecoder().decode([UUID: String].self, from: data)
        {
            acpSessions = decoded.filter { chatAgents[$0.key] != nil }
        }
    }

    func acpSession(forChat chatID: UUID) -> String? {
        acpSessions[chatID]
    }

    func setACPSession(_ id: String?, forChat chatID: UUID) {
        guard acpSessions[chatID] != id else { return }
        acpSessions[chatID] = id
        guard let data = try? JSONEncoder().encode(acpSessions) else { return }
        try? data.write(to: acpSessionsURL, options: .atomic)
    }

    func agent(id: UUID) -> AgentProfile? {
        agents.first { $0.id == id }
    }

    func agent(forChat chatID: UUID) -> AgentProfile? {
        chatAgents[chatID].flatMap(agent(id:))
    }

    @discardableResult
    func add(_ draft: AgentProfile) throws(AgentProfileError) -> AgentProfile {
        let value = try validated(draft)
        try commit(agents + [value])
        return value
    }

    func update(_ draft: AgentProfile) throws(AgentProfileError) {
        guard let index = agents.firstIndex(where: { $0.id == draft.id }) else { return }
        var updated = agents
        updated[index] = try validated(draft)
        try commit(updated)
    }

    func remove(id: UUID) throws(AgentProfileError) {
        try commit(agents.filter { $0.id != id })
        let chats = chatAgents.filter { $0.value == id }.map(\.key)
        bind(chats, to: nil)
        for chat in chats { setACPSession(nil, forChat: chat) }
    }

    /// A chat's agent; nil takes the chat back to plain AI.
    func setAgent(_ id: UUID?, forChat chatID: UUID) {
        bind([chatID], to: id)
    }

    private func bind(_ chats: [UUID], to agent: UUID?) {
        guard !chats.isEmpty else { return }
        for chat in chats { chatAgents[chat] = agent }
        guard let data = try? JSONEncoder().encode(chatAgents) else { return }
        try? data.write(to: bindingsURL, options: .atomic)
    }

    private func validated(_ draft: AgentProfile) throws(AgentProfileError) -> AgentProfile {
        var value = draft
        value.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.directory = draft.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else { throw .emptyName }
        guard !value.directory.isEmpty else { throw .missingDirectory }
        return value
    }

    /// Nothing moves until it is on disk, so a failed write never shows as saved.
    private func commit(_ updated: [AgentProfile]) throws(AgentProfileError) {
        guard isAvailable else { throw .storageUnavailable }
        guard let data = try? JSONEncoder().encode(updated) else { throw .storageUnavailable }
        do {
            try data.write(to: agentsURL, options: .atomic)
        } catch {
            throw .storageUnavailable
        }
        agents = updated
    }
}
