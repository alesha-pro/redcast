import Foundation

/// ACP agents for AI Chat: a process per agent, a session per chat, and each turn's stream.
@MainActor
final class AgentACPHost {
    private let store: AgentStore
    /// The user's answer to a permission request; nil cancels it.
    private let permit: (AgentProfile, ACPPermissionRequest) async -> String?
    /// What a fresh session is told about the agent: its notes, skills and instructions.
    private let context: (AgentProfile) -> String?

    /// A session's modes changed: on creation, on a reload, or by the agent's own move.
    var onModes: ((_ chatID: UUID, _ agentID: UUID, ACPModes) -> Void)?
    /// A session listed its slash commands; the chat is nil while the session is not yet bound.
    var onCommands: ((_ chatID: UUID?, _ agentID: UUID, [ACPCommand]) -> Void)?

    private var connections: [UUID: ACPConnection] = [:]
    private var modes: [UUID: ACPModes] = [:]
    private var sessions: [UUID: Session] = [:]
    private var turns: [Session: Turn] = [:]
    private var idleStops: [UUID: Task<Void, Never>] = [:]
    /// The latest list per live session; it goes with the agent's process.
    private var commands: [Session: [ACPCommand]] = [:]
    /// New sessions not yet briefed: a slash command's turn leaves the briefing for the next one.
    private var unbriefed: Set<Session> = []

    /// An agent left alone this long is stopped; its sessions reload on the next turn.
    private static let idleLifetime: Duration = .seconds(2 * 60)

    /// A session id is the agent's own, so two agents can both say `sess_1`; the pair is unique.
    private struct Session: Hashable {
        let agentID: UUID
        let id: String
    }

    private final class Turn {
        let continuation: AIProviderStream.Continuation
        var mapper: ACPEventMapper

        init(continuation: AIProviderStream.Continuation, mapper: ACPEventMapper) {
            self.continuation = continuation
            self.mapper = mapper
        }
    }

    init(
        store: AgentStore,
        permit: @escaping (AgentProfile, ACPPermissionRequest) async -> String?,
        context: @escaping (AgentProfile) -> String?
    ) {
        self.store = store
        self.permit = permit
        self.context = context
    }

    func run(
        _ request: AIRequest, agent: AgentProfile, servers: [AIToolServer],
        into continuation: AIProviderStream.Continuation
    ) async {
        guard let chatID = request.conversationID,
            let message = request.messages.last(where: { $0.role == .user })
        else {
            continuation.finish(throwing: AIProviderError.unavailable("This chat has no message to send."))
            return
        }
        idleStops[agent.id]?.cancel()
        defer { scheduleIdleStop(agent.id) }
        var sessionID: String?
        do {
            let connection = try await connection(for: agent)
            let session = try await session(for: chatID, agent: agent, on: connection, servers: servers)
            sessionID = session
            let key = Session(agentID: agent.id, id: session)
            let offered = commands[key] ?? commands.first { $0.key.agentID == agent.id }?.value ?? []
            let isCommand = ACPCommand.invocation(in: message.text, offered: offered) != nil
            let briefs = !isCommand && unbriefed.remove(key) != nil
            let history = briefs ? request.messages.dropLast().filter {
                $0.role == .user || $0.role == .assistant
            } : []
            let blocks = ACPPrompt.blocks(
                for: message, context: briefs ? context(agent) : nil, history: Array(history),
                capabilities: connection.capabilities.prompt, asCommand: isCommand)
            let turn = Turn(continuation: continuation, mapper: ACPEventMapper(origin: agent.name))
            turns[key] = turn
            defer { turns[key] = nil }
            let result = try await connection.request(
                "session/prompt", params: ["sessionId": session, "prompt": blocks], timeout: nil)
            connection.rememberTree()
            for event in turn.mapper.closing(result: result) { continuation.yield(event) }
            if result.objectValue?["stopReason"]?.stringValue == "refusal" {
                continuation.finish(
                    throwing: AIProviderError.responseFailed(
                        String(localized: "The agent declined this request.")))
                return
            }
            continuation.yield(.finished)
            continuation.finish()
        } catch is CancellationError {
            if let sessionID { connections[agent.id]?.cancel(sessionID: sessionID) }
            continuation.finish()
        } catch {
            continuation.finish(throwing: AIProviderError.responseFailed(error.localizedDescription))
        }
    }

    /// A chat's session ends with its agent: the next turn starts or reloads one.
    func forget(chatID: UUID) {
        if let live = sessions.removeValue(forKey: chatID) {
            commands[live] = nil
            unbriefed.remove(live)
        }
        store.setACPSession(nil, forChat: chatID)
    }

    /// A permission request names its session, never its chat; this is the only map back.
    func chatID(forSession id: String, of agentID: UUID) -> UUID? {
        let wanted = Session(agentID: agentID, id: id)
        return sessions.first { $0.value == wanted }?.key
    }

    /// For a run nobody is watching: the agent goes as soon as no turn of its is left.
    func release(agentID: UUID) {
        guard let connection = connections[agentID] else { return }
        guard !turns.keys.contains(where: { $0.agentID == agentID }) else { return }
        idleStops.removeValue(forKey: agentID)?.cancel()
        connections[agentID] = nil
        dropSessions(of: agentID)
        connection.stop()
    }

    func stopAll() {
        for connection in connections.values { connection.stop() }
        connections.removeAll()
        sessions.removeAll()
        commands.removeAll()
        for task in idleStops.values { task.cancel() }
        idleStops.removeAll()
    }

    // MARK: - Private

    private func connection(for agent: AgentProfile) async throws -> ACPConnection {
        if let existing = connections[agent.id], existing.isRunning,
            existing.runtime == agent.runtime, existing.directory == agent.directory
        {
            return existing
        }
        connections[agent.id]?.stop()
        guard let runtime = agent.runtime else {
            throw ACPConnection.ConnectionError.launchFailed("This agent runs on the chat's model.")
        }
        let connection = ACPConnection(runtime: runtime, directory: agent.directory)
        connection.onUpdate = { [weak self] sessionID, update in
            self?.route(update, to: Session(agentID: agent.id, id: sessionID))
        }
        connection.onPermission = { [weak self] request in
            await self?.permit(agent, request)
        }
        connection.onExit = { [weak self, weak connection] _ in
            guard let self, let connection, self.connections[agent.id] === connection else { return }
            self.connections[agent.id] = nil
            self.dropSessions(of: agent.id)
        }
        connections[agent.id] = connection
        do {
            try await connection.start()
        } catch {
            connections[agent.id] = nil
            throw error
        }
        dropSessions(of: agent.id)
        return connection
    }

    /// The process is gone or going; a pending briefing stays, as a reload still needs it.
    private func dropSessions(of agentID: UUID) {
        sessions = sessions.filter { $0.value.agentID != agentID }
        commands = commands.filter { $0.key.agentID != agentID }
    }

    private func session(
        for chatID: UUID, agent: AgentProfile, on connection: ACPConnection, servers: [AIToolServer]
    ) async throws -> String {
        if let live = sessions[chatID], live.agentID == agent.id { return live.id }
        let mcpServers = servers.compactMap { Self.mcpServer($0, http: connection.capabilities.mcpHTTP) }
        // A reload replays the history as updates no turn is listening for, so they are dropped.
        if let stored = store.acpSession(forChat: chatID), connection.capabilities.loadSession,
            let loaded = try? await connection.request(
                "session/load",
                params: ["sessionId": stored, "cwd": agent.directory, "mcpServers": mcpServers],
                timeout: .seconds(120))
        {
            bind(chatID, to: Session(agentID: agent.id, id: stored))
            await adopt(ACPModes(result: loaded), session: stored, chatID: chatID, agent: agent, on: connection)
            return stored
        }
        let result = try await connection.request(
            "session/new", params: ["cwd": agent.directory, "mcpServers": mcpServers],
            timeout: .seconds(120))
        guard let id = result.objectValue?["sessionId"]?.stringValue else {
            throw ACPConnection.ConnectionError.requestFailed(
                String(localized: "The agent didn't start a session."))
        }
        if let lost = store.acpSession(forChat: chatID) {
            unbriefed.remove(Session(agentID: agent.id, id: lost))
        }
        unbriefed.insert(Session(agentID: agent.id, id: id))
        bind(chatID, to: Session(agentID: agent.id, id: id))
        store.setACPSession(id, forChat: chatID)
        await adopt(ACPModes(result: result), session: id, chatID: chatID, agent: agent, on: connection)
        return id
    }

    /// An agent may list its commands before the session's reply has been read, so they wait here.
    private func bind(_ chatID: UUID, to session: Session) {
        sessions[chatID] = session
        if let listed = commands[session] { onCommands?(chatID, session.agentID, listed) }
    }

    /// The agent's chosen mode is applied as a session starts, when the agent still offers it.
    private func adopt(
        _ offered: ACPModes?, session: String, chatID: UUID, agent: AgentProfile,
        on connection: ACPConnection
    ) async {
        guard var offered else { return }
        if let wanted = agent.acpMode, wanted != offered.current,
            offered.available.contains(where: { $0.id == wanted }),
            (try? await connection.request(
                "session/set_mode", params: ["sessionId": session, "modeId": wanted])) != nil
        {
            offered.current = wanted
        }
        modes[chatID] = offered
        onModes?(chatID, agent.id, offered)
    }

    /// A live session switches now; otherwise the choice waits for the next session to start.
    func setMode(_ modeID: String, chatID: UUID) async throws {
        guard let live = sessions[chatID], let connection = connections[live.agentID],
            var current = modes[chatID]
        else { return }
        _ = try await connection.request(
            "session/set_mode", params: ["sessionId": live.id, "modeId": modeID])
        current.current = modeID
        modes[chatID] = current
        onModes?(chatID, live.agentID, current)
    }

    private func route(_ update: ACPUpdate, to session: Session) {
        let chatID = sessions.first { $0.value == session }?.key
        if case .mode(let mode) = update, let chatID, var current = modes[chatID] {
            current.current = mode
            modes[chatID] = current
            onModes?(chatID, session.agentID, current)
        }
        if case .commands(let listed) = update {
            commands[session] = listed
            onCommands?(chatID, session.agentID, listed)
        }
        guard let turn = turns[session] else { return }
        for event in turn.mapper.events(for: update) { turn.continuation.yield(event) }
    }

    private func scheduleIdleStop(_ agentID: UUID) {
        idleStops[agentID]?.cancel()
        idleStops[agentID] = Task { [weak self] in
            try? await Task.sleep(for: Self.idleLifetime)
            guard !Task.isCancelled, let self else { return }
            self.connections.removeValue(forKey: agentID)?.stop()
            self.dropSessions(of: agentID)
            self.idleStops[agentID] = nil
        }
    }

    /// Tinycast's MCP servers, in ACP's shape; a remote one only for an agent that takes HTTP.
    static func mcpServer(_ server: AIToolServer, http: Bool) -> [String: Any]? {
        switch server.transport {
        case .command(let path, let arguments, let environment):
            return [
                "name": server.handle, "command": path, "args": arguments,
                "env": environment.sorted { $0.key < $1.key }.map { ["name": $0.key, "value": $0.value] }
            ]
        case .url(let url, let headerName, let headerValue):
            guard http else { return nil }
            let headers = headerName.isEmpty ? [] : [["name": headerName, "value": headerValue]]
            return ["type": "http", "name": server.handle, "url": url, "headers": headers]
        }
    }
}

/// An ACP agent as an `AIProvider`, so a chat streams it like any other route.
struct ACPAgentProvider: AIProvider {
    let host: AgentACPHost
    let agent: AgentProfile
    let servers: @Sendable () async -> [AIToolServer]

    func stream(_ request: AIRequest) -> AIProviderStream {
        AIProviderStream { continuation in
            let task = Task { @MainActor in
                let servers = await servers()
                await host.run(request, agent: agent, servers: servers, into: continuation)
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }
}
