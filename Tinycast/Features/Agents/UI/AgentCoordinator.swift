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
    /// "Allow for This Chat", per kind of request; never written down.
    @ObservationIgnored private var chatGrants: [UUID: Set<AgentConsentRequest.Kind>] = [:]

    init(store: AgentStore, core: AppCore) {
        self.store = store
        self.core = core
    }

    var agents: [AgentProfile] { store.agents }

    func agent(for chat: AIChatState) -> AgentProfile? {
        store.agent(forChat: chat.session.id)
    }

    func setAgent(_ agent: AgentProfile?, for chat: AIChatState) {
        store.setAgent(agent?.id, forChat: chat.session.id)
        chatGrants[chat.session.id] = nil
        if let agent { refresh(agent) }
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

    func tools(for chat: AIChatState) -> [AITool] {
        guard let agent = agent(for: chat) else { return [] }
        return AgentToolbox.tools(for: agent, hasSkills: !context(for: agent).skills.isEmpty)
    }

    func executor(for chat: AIChatState) -> AgentToolExecutor? {
        guard let agent = agent(for: chat) else { return nil }
        let chatID = chat.session.id
        return AgentToolExecutor(
            profile: agent, skills: context(for: agent).skills,
            memoryURL: store.memoryURL(for: agent.id)
        ) { [weak self] request in
            await self?.permit(request, by: agent, in: chatID) ?? false
        }
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

    private func permit(
        _ request: AgentConsentRequest, by agent: AgentProfile, in chatID: UUID
    ) async -> Bool {
        if chatGrants[chatID]?.contains(request.kind) == true { return true }
        let title =
            switch request.kind {
            case .command: String(localized: "\(agent.name) wants to run a command")
            case .write: String(localized: "\(agent.name) wants to change a file")
            }
        NSApp.activate(ignoringOtherApps: true)
        let answer = await core.choose(
            title: title, message: request.summary + "\n\n" + request.detail, symbol: agent.symbol,
            options: [
                DialogAction(title: String(localized: "Allow")),
                DialogAction(title: String(localized: "Allow for This Chat")),
                DialogAction(title: String(localized: "Don't Allow"), role: .cancel)
            ], defaultIndex: 0)
        switch answer {
        case 0: return true
        case 1:
            chatGrants[chatID, default: []].insert(request.kind)
            return true
        default: return false
        }
    }

    // MARK: - Editing

    func add(_ draft: AgentProfile) throws(AgentProfileError) {
        let agent = try store.add(draft)
        refresh(agent)
    }

    func update(_ draft: AgentProfile) throws(AgentProfileError) {
        try store.update(draft)
        contexts[draft.id] = nil
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
