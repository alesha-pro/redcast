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
    /// Chat id to what its session was last on; lives as long as the session id beside it.
    private(set) var acpChoices: [UUID: ACPChoices] = [:]
    /// False when the file wouldn't read; every mutation then refuses rather than pretends.
    private(set) var isAvailable = true
    private(set) var schedules: [AgentSchedule] = []
    /// Schedule id to its baseline; the next run is the first occurrence after it.
    private(set) var scheduleBaselines: [UUID: Date] = [:]
    /// The schedules file's own `isAvailable`: authored data, never written over unread.
    private(set) var schedulesAvailable = true
    /// The daily cap and what scheduled runs spent today; a file that won't read caps at zero.
    private(set) var scheduleSpend = AgentScheduleSpend()

    private let agentsURL: URL
    /// Families the previous build cannot read, per agent; its rewrite of agents.json drops them.
    private let newerToolsURL: URL
    /// Each agent's colour, apart from agents.json, which the previous build rewrites without it.
    private let colorsURL: URL
    private let bindingsURL: URL
    private let acpSessionsURL: URL
    private let acpChoicesURL: URL
    private let schedulesURL: URL
    /// Kept apart from the schedules, so a run never rewrites what the user wrote.
    private let scheduleBaselinesURL: URL
    private let scheduleSpendURL: URL
    /// Until the cap is set again, a run's spend is kept in memory over a file that won't read.
    private var scheduleSpendWritable = true
    let directory: URL

    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory
        self.directory = base
        agentsURL = base.appendingPathComponent("agents.json")
        newerToolsURL = base.appendingPathComponent("agent-newer-tools.json")
        colorsURL = base.appendingPathComponent("agent-colors.json")
        bindingsURL = base.appendingPathComponent("agent-chats.json")
        acpSessionsURL = base.appendingPathComponent("agent-acp-sessions.json")
        acpChoicesURL = base.appendingPathComponent("agent-acp-choices.json")
        schedulesURL = base.appendingPathComponent("agent-schedules.json")
        scheduleBaselinesURL = base.appendingPathComponent("agent-schedule-runs.json")
        scheduleSpendURL = base.appendingPathComponent("agent-schedule-spend.json")
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

    /// Where an agent chat keeps its notes on the turns its requests no longer carry.
    func summaryURL(forChat id: UUID) -> URL {
        summariesDirectory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    func removeSummary(forChat id: UUID) {
        try? FileManager.default.removeItem(at: summaryURL(forChat: id))
    }

    /// Every chat's notes but those of `chats` go: what deleting chats in bulk leaves to sweep.
    func pruneSummaries(keeping chats: some Sequence<UUID>) {
        let kept = Set(chats)
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: summariesDirectory, includingPropertiesForKeys: nil)
        else { return }
        for file in files {
            let chat = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
            if chat.map(kept.contains) != true { try? FileManager.default.removeItem(at: file) }
        }
    }

    private var summariesDirectory: URL {
        directory.appendingPathComponent("agent-summaries", isDirectory: true)
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
            agents = restoringColors(restoringNewerTools(decoded, from: data))
                .sorted { $0.createdAt < $1.createdAt }
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
        if let data = try? Data(contentsOf: acpChoicesURL),
            let decoded = try? JSONDecoder().decode([UUID: ACPChoices].self, from: data)
        {
            acpChoices = decoded.filter { acpSessions[$0.key] != nil }
        }
        loadSchedules()
    }

    private func loadSchedules() {
        if FileManager.default.fileExists(atPath: schedulesURL.path) {
            guard let data = try? Data(contentsOf: schedulesURL),
                let decoded = try? JSONDecoder().decode([AgentSchedule].self, from: data)
            else {
                schedulesAvailable = false
                return
            }
            let known = Set(agents.map(\.id))
            schedules = decoded.filter { known.contains($0.agentID) }
        }
        if let data = try? Data(contentsOf: scheduleBaselinesURL),
            let decoded = try? JSONDecoder().decode([UUID: Date].self, from: data)
        {
            let known = Set(schedules.map(\.id))
            scheduleBaselines = decoded.filter { known.contains($0.key) }
        }
        guard FileManager.default.fileExists(atPath: scheduleSpendURL.path) else { return }
        if let data = try? Data(contentsOf: scheduleSpendURL),
            let decoded = try? JSONDecoder().decode(AgentScheduleSpend.self, from: data)
        {
            scheduleSpend = decoded
        } else {
            // Fails closed: a cap that can't be read holds every schedule rather than lifting it.
            scheduleSpend = AgentScheduleSpend(capUSD: 0)
            scheduleSpendWritable = false
        }
    }

    func acpSession(forChat chatID: UUID) -> String? {
        acpSessions[chatID]
    }

    func setACPSession(_ id: String?, forChat chatID: UUID) {
        if id == nil { setACPChoices(nil, forChat: chatID) }
        guard acpSessions[chatID] != id else { return }
        acpSessions[chatID] = id
        guard let data = try? JSONEncoder().encode(acpSessions) else { return }
        try? data.write(to: acpSessionsURL, options: .atomic)
    }

    func acpChoices(forChat chatID: UUID) -> ACPChoices? {
        acpChoices[chatID]
    }

    /// Runtime state like the session ids: a failed write only costs a reload its picks.
    func setACPChoices(_ choices: ACPChoices?, forChat chatID: UUID) {
        let kept = acpSessions[chatID] == nil || choices == ACPChoices() ? nil : choices
        guard acpChoices[chatID] != kept else { return }
        acpChoices[chatID] = kept
        guard let data = try? JSONEncoder().encode(acpChoices) else { return }
        try? data.write(to: acpChoicesURL, options: .atomic)
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
        for chat in chats {
            setACPSession(nil, forChat: chat)
            removeSummary(forChat: chat)
        }
        let orphaned = schedules.filter { $0.agentID == id }.map(\.id)
        guard !orphaned.isEmpty else { return }
        // An unreadable file is filtered by agent on the next load, so it is left as it is.
        try? commitSchedules(schedules.filter { $0.agentID != id })
        dropBaselines(orphaned)
    }

    // MARK: - Schedules

    func schedules(forAgent id: UUID) -> [AgentSchedule] {
        schedules.filter { $0.agentID == id }
    }

    func schedule(id: UUID) -> AgentSchedule? {
        schedules.first { $0.id == id }
    }

    /// When the next run is counted from: its last run, or since it last started counting.
    func baseline(for schedule: AgentSchedule) -> Date {
        scheduleBaselines[schedule.id] ?? schedule.createdAt
    }

    /// Adds or replaces; a new, re-enabled or re-timed schedule starts counting from `now`.
    @discardableResult
    func saveSchedule(_ draft: AgentSchedule, now: Date) throws(AgentScheduleError) -> AgentSchedule {
        var value = draft
        value.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        value.noteTitle = draft.noteTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.noteTitle?.isEmpty == true { value.noteTitle = nil }
        guard !value.name.isEmpty else { throw .emptyName }
        guard !value.prompt.isEmpty else { throw .emptyPrompt }
        guard value.rule.isValid else { throw .invalidRule }
        let previous = schedule(id: value.id)
        var updated = schedules
        if let index = updated.firstIndex(where: { $0.id == value.id }) {
            updated[index] = value
        } else {
            updated.append(value)
        }
        try commitSchedules(updated)
        let restarts =
            previous == nil || previous?.rule != value.rule
            || (previous?.isEnabled == false && value.isEnabled)
        if restarts { setBaseline(now, forSchedule: value.id) }
        return value
    }

    func removeSchedule(id: UUID) throws(AgentScheduleError) {
        try commitSchedules(schedules.filter { $0.id != id })
        dropBaselines([id])
    }

    func setBaseline(_ date: Date, forSchedule id: UUID) {
        guard schedule(id: id) != nil, scheduleBaselines[id] != date else { return }
        scheduleBaselines[id] = date
        writeBaselines()
    }

    /// The user's own gesture, so it writes even over a file that wouldn't read.
    func setScheduleCap(_ cap: Double?) throws(AgentScheduleError) {
        var updated = scheduleSpend
        updated.capUSD = AgentSpendPolicy.cap(cap)
        guard let data = try? JSONEncoder().encode(updated) else { throw .storageUnavailable }
        do {
            try data.write(to: scheduleSpendURL, options: .atomic)
        } catch {
            throw .storageUnavailable
        }
        scheduleSpend = updated
        scheduleSpendWritable = true
    }

    /// Runtime state like the baselines: a failed write only forgets part of today's spend.
    func recordScheduledSpend(_ cost: Double, on day: String) {
        scheduleSpend = AgentSpendPolicy.adding(cost, to: scheduleSpend, on: day)
        guard scheduleSpendWritable, let data = try? JSONEncoder().encode(scheduleSpend) else { return }
        try? data.write(to: scheduleSpendURL, options: .atomic)
    }

    private func dropBaselines(_ ids: [UUID]) {
        let kept = scheduleBaselines.filter { !ids.contains($0.key) }
        guard kept.count != scheduleBaselines.count else { return }
        scheduleBaselines = kept
        writeBaselines()
    }

    /// Runtime state, so a failed write only costs a catch-up run, never a schedule.
    private func writeBaselines() {
        guard let data = try? JSONEncoder().encode(scheduleBaselines) else { return }
        try? data.write(to: scheduleBaselinesURL, options: .atomic)
    }

    private func commitSchedules(_ updated: [AgentSchedule]) throws(AgentScheduleError) {
        guard isAvailable, schedulesAvailable,
            let data = try? JSONEncoder().encode(updated)
        else { throw .storageUnavailable }
        do {
            try data.write(to: schedulesURL, options: .atomic)
        } catch {
            throw .storageUnavailable
        }
        schedules = updated
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
            // First, so the side file is never older than the agents.json it restores.
            try writeNewerTools(of: updated)
            try writeColors(of: updated)
            try data.write(to: agentsURL, options: .atomic)
        } catch {
            throw .storageUnavailable
        }
        agents = updated
    }

    private func writeNewerTools(of agents: [AgentProfile]) throws {
        var newer: [UUID: [String]] = [:]
        for agent in agents {
            let names = agent.tools.intersection(AgentToolKind.unknownToOlderBuilds).map(\.rawValue).sorted()
            if !names.isEmpty { newer[agent.id] = names }
        }
        guard !newer.isEmpty else {
            if FileManager.default.fileExists(atPath: newerToolsURL.path) {
                try FileManager.default.removeItem(at: newerToolsURL)
            }
            return
        }
        try JSONEncoder().encode(newer).write(to: newerToolsURL, options: .atomic)
    }

    private func writeColors(of agents: [AgentProfile]) throws {
        let colors = agents.reduce(into: [UUID: String]()) { $0[$1.id] = $1.color }
        guard !colors.isEmpty else {
            if FileManager.default.fileExists(atPath: colorsURL.path) {
                try FileManager.default.removeItem(at: colorsURL)
            }
            return
        }
        try JSONEncoder().encode(colors).write(to: colorsURL, options: .atomic)
    }

    /// An agent the previous build saved has lost `color`; it gets the one this build last wrote.
    private func restoringColors(_ decoded: [AgentProfile]) -> [AgentProfile] {
        guard let saved = try? Data(contentsOf: colorsURL),
            let colors = try? JSONDecoder().decode([UUID: String].self, from: saved)
        else { return decoded }
        return decoded.map { agent in
            guard agent.color == nil, let color = colors[agent.id] else { return agent }
            var restored = agent
            restored.color = color
            return restored
        }
    }

    /// The previous build's save drops `addedTools`; such an agent gets what this build last wrote.
    private func restoringNewerTools(_ decoded: [AgentProfile], from data: Data) -> [AgentProfile] {
        guard let saved = try? Data(contentsOf: newerToolsURL),
            let newer = try? JSONDecoder().decode([UUID: [String]].self, from: saved),
            let objects = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return decoded }
        let rewritten = Set(
            objects.filter { $0["addedTools"] == nil }
                .compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) })
        return decoded.map { agent in
            guard rewritten.contains(agent.id), let names = newer[agent.id] else { return agent }
            var restored = agent
            let families = names.compactMap(AgentToolKind.init(rawValue:))
            restored.tools.formUnion(families.filter(AgentToolKind.unknownToOlderBuilds.contains))
            return restored
        }
    }
}
