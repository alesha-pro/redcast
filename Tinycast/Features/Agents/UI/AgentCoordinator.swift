import AppKit
import Observation

/// Agents for AI Chat: which chat has one, what its turns are told, and running its tools.
@MainActor
@Observable
final class AgentCoordinator {
    let store: AgentStore
    private unowned let core: AppCore

    /// Read off-main and kept, so a send never waits on the disk; refreshed after every use.
    @ObservationIgnored private var contexts: [UUID: AgentContext] = [:]
    @ObservationIgnored private var refreshing: Set<UUID> = []
    /// "Allow for This Chat", per family and risk; never written down.
    @ObservationIgnored private var chatGrants: [UUID: Set<AgentGrant>] = [:]

    @ObservationIgnored private(set) lazy var acpHost: AgentACPHost = {
        let host = AgentACPHost(
            store: store,
            permit: { [weak self] agent, request in await self?.permit(request, by: agent) },
            context: { [weak self] agent in self?.context(for: agent).briefing() })
        host.onModes = { [weak self] chatID, agentID, modes in
            self?.chatModes[chatID] = modes
            self?.agentModes[agentID] = modes.available
        }
        return host
    }()

    /// Observed: the composer's mode menu follows the session, including the agent's own moves.
    private(set) var chatModes: [UUID: ACPModes] = [:]
    /// What the agent offered last time, so a new chat can pick a mode before its first message.
    private(set) var agentModes: [UUID: [ACPModes.Mode]] = [:]

    init(store: AgentStore, core: AppCore) {
        self.store = store
        self.core = core
    }

    var agents: [AgentProfile] { store.agents }

    func agent(for chat: AIChatState) -> AgentProfile? {
        store.agent(forChat: chat.session.id)
    }

    func setAgent(_ agent: AgentProfile?, for chat: AIChatState) {
        guard store.agent(forChat: chat.session.id)?.id != agent?.id else { return }
        store.setAgent(agent?.id, forChat: chat.session.id)
        chatGrants[chat.session.id] = nil
        acpHost.forget(chatID: chat.session.id)
        if let agent { refresh(agent) }
    }

    /// A chat whose agent brings its own CLI: the model picker has nothing to say about it.
    func runsOwnRuntime(_ chat: AIChatState) -> Bool {
        agent(for: chat)?.runtime != nil
    }

    func acpProvider(
        for chat: AIChatState, servers: @escaping @Sendable () async -> [AIToolServer]
    ) -> (any AIProvider)? {
        guard let agent = agent(for: chat), agent.runtime != nil else { return nil }
        return ACPAgentProvider(host: acpHost, agent: agent, servers: servers)
    }

    func stopAll() {
        acpHost.stopAll()
    }

    func modes(for chat: AIChatState) -> ACPModes? {
        guard let agent = agent(for: chat), agent.runtime != nil else { return nil }
        if let live = chatModes[chat.session.id] { return live }
        guard let offered = agentModes[agent.id] else { return nil }
        return ACPModes(current: agent.acpMode, available: offered)
    }

    /// Remembered on the agent for every new session, and applied now to a live one.
    func setMode(_ modeID: String, for chat: AIChatState) {
        guard var agent = agent(for: chat) else { return }
        agent.acpMode = modeID
        try? store.update(agent)
        let chatID = chat.session.id
        if var live = chatModes[chatID] {
            live.current = modeID
            chatModes[chatID] = live
        }
        Task { [weak self] in
            do {
                try await self?.acpHost.setMode(modeID, chatID: chatID)
            } catch {
                self?.core.showMessage(error.localizedDescription, tone: .danger)
            }
        }
    }

    /// A fresh AI Chat that already belongs to the agent, ready for the first message.
    func startChat(with agent: AgentProfile) {
        let chats = core.aiChatCoordinator.chats
        core.aiChatCoordinator.newChat()
        setAgent(agent, for: chats.window)
        core.aiChatCoordinator.showWindow()
    }

    // MARK: - A turn

    /// The agent's part of the instructions; nil for a chat without one.
    func prompt(for chat: AIChatState, hasTools: Bool) -> String? {
        guard let agent = agent(for: chat) else { return nil }
        return context(for: agent).prompt(now: Date(), timeZone: .current, hasTools: hasTools)
    }

    /// An agent chat's turn on the fork's loop, MCP's tools beside its own; nil leaves it upstream.
    func loop(over base: any AIProvider, mcpTools: [AITool], in chat: AIChatState) -> (any AIProvider)? {
        guard let agent = agent(for: chat), agent.runtime == nil else { return nil }
        let chatID = chat.session.id
        let mcp = core.mcpCoordinator
        return loop(for: agent, over: base, mode: .chat(chatID), mcpTools: mcpTools) { call in
            await mcp.invoke(call, in: chatID)
        }
    }

    /// The one place a turn's tools are assembled: a chat now, a run with no window later.
    func loop(
        for agent: AgentProfile, over base: any AIProvider, mode: AgentRunMode,
        mcpTools: [AITool] = [],
        mcp: @escaping @Sendable (AIToolCall) async -> AIToolResult = {
            .failure($0.id, "There is no tool called \($0.name).")
        }
    ) -> AgentLoopProvider? {
        let context = context(for: agent)
        let turn = AgentTurn(
            profile: agent, skills: context.skills, memoryURL: store.memoryURL(for: agent.id),
            mode: mode)
        let toolset = AgentToolset(
            turn: turn, providers: providers(for: agent), mcpTools: mcpTools, mcp: mcp
        ) { [weak self] spec, request in
            guard case .chat(let chatID) = mode else { return false }
            return await self?.ask(spec, request, by: agent, in: chatID) ?? false
        }
        guard !toolset.tools.isEmpty else { return nil }
        return AgentLoopProvider(
            base: base, toolset: toolset, maxRounds: core.aiSettings.toolRounds.limit)
    }

    /// The registry: one line per family, built per turn so nothing stays resident between turns.
    private func providers(for agent: AgentProfile) -> [any AgentToolProvider] {
        var providers: [any AgentToolProvider] = [AgentBuiltInTools()]
        if agent.tools.contains(.web) {
            providers.append(WebSearchAgentTools(runner: core.webSearch.runner(canFetch: true)))
        }
        return providers
    }

    /// The cached reading when there is one; the first ever is read in place, the rest refresh.
    private func context(for agent: AgentProfile) -> AgentContext {
        defer { refresh(agent) }
        if let cached = contexts[agent.id], cached.profile == agent { return cached }
        let loaded = AgentContextLoader.load(agent, memoryURL: store.memoryURL(for: agent.id))
        contexts[agent.id] = loaded
        return loaded
    }

    func refresh(_ agent: AgentProfile) {
        guard refreshing.insert(agent.id).inserted else { return }
        let memoryURL = store.memoryURL(for: agent.id)
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                AgentContextLoader.load(agent, memoryURL: memoryURL)
            }.value
            guard let self else { return }
            self.refreshing.remove(agent.id)
            if self.store.agent(id: agent.id) == agent { self.contexts[agent.id] = loaded }
        }
    }

    // MARK: - Consent

    /// The dialog behind a rule of ask; a chat grant skips it, and Stop voids its answer.
    private func ask(
        _ spec: AgentToolSpec, _ request: AgentConsentRequest, by agent: AgentProfile, in chatID: UUID
    ) async -> Bool {
        if chatGrants[chatID]?.contains(spec.grant) == true { return true }
        let title =
            switch (spec.family, spec.risk) {
            case (_, .execute): String(localized: "\(agent.name) wants to run a command")
            case (.files?, .change): String(localized: "\(agent.name) wants to change a file")
            default: String(localized: "\(agent.name) wants to use \(spec.tool.title)")
            }
        NSApp.activate(ignoringOtherApps: true)
        let answer = await core.choose(
            title: title,
            message: [request.summary, request.detail].filter { !$0.isEmpty }.joined(separator: "\n\n"),
            symbol: agent.symbol,
            options: [
                DialogAction(title: String(localized: "Allow")),
                DialogAction(title: String(localized: "Allow for This Chat")),
                DialogAction(title: String(localized: "Don't Allow"), role: .cancel)
            ], defaultIndex: 0)
        // Stop while the dialog was up: the turn is gone, so its answer must not act.
        guard !Task.isCancelled else { return false }
        switch answer {
        case 0: return true
        case 1:
            chatGrants[chatID, default: []].insert(spec.grant)
            return true
        default: return false
        }
    }

    /// The agent's own options, allows first; the last is the dialog's cancel and refuses once.
    private func permit(_ request: ACPPermissionRequest, by agent: AgentProfile) async -> String? {
        let options = request.dialogOptions
        guard !options.isEmpty else { return nil }
        let title = request.toolCall.title ?? request.toolCall.kind ?? String(localized: "Use a tool")
        let summary = request.toolCall.summary
        NSApp.activate(ignoringOtherApps: true)
        let answer = await core.choose(
            title: String(localized: "\(agent.name): \(title)"),
            message: summary.isEmpty ? nil : summary, symbol: agent.symbol,
            options: options.enumerated().map { index, option in
                DialogAction(
                    title: option.name,
                    role: index == options.count - 1 && !option.allows
                        ? .cancel : option.allows ? .standard : .destructive)
            }, defaultIndex: 0)
        return options.indices.contains(answer) ? options[answer].id : nil
    }

    // MARK: - Editing

    func add(_ draft: AgentProfile) throws(AgentProfileError) {
        let agent = try store.add(draft)
        refresh(agent)
    }

    func update(_ draft: AgentProfile) throws(AgentProfileError) {
        let previous = store.agent(id: draft.id)
        try store.update(draft)
        contexts[draft.id] = nil
        // A different program or folder is a different agent: its old sessions mean nothing.
        if previous?.runtime != draft.runtime || previous?.directory != draft.directory {
            for (chat, agent) in store.chatAgents where agent == draft.id {
                acpHost.forget(chatID: chat)
            }
        }
        if let agent = store.agent(id: draft.id) { refresh(agent) }
    }

    func delete(id: UUID) async {
        guard let agent = store.agent(id: id) else { return }
        guard
            await core.confirm(
                title: String(localized: "Delete “\(agent.name)”?"),
                message: String(
                    localized: "Its chats stay, as plain AI chats. Its notes are deleted with it."),
                symbol: agent.symbol, confirmTitle: String(localized: "Delete"))
        else { return }
        do {
            try store.remove(id: id)
        } catch {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        contexts[id] = nil
        try? FileManager.default.removeItem(at: store.memoryURL(for: id).deletingLastPathComponent())
    }
}
