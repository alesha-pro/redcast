import Foundation

/// A chat before its first message: AI Chat's agent from Settings and a chat's own No Agent.
extension AgentCoordinator {
    /// Settings' pick for AI Chat's new chats, native or ACP, while AI is on and the agent exists.
    var chatAgent: AgentProfile? {
        ChatToolPolicy.windowAgent(picked: chatDefault.agentID, aiEnabled: core.settings.aiEnabled) {
            store.agent(id: $0)
        }
    }

    /// The composer's or ⌘K's pick; No Agent on an unsent chat keeps Settings' agent out of it too.
    func chooseAgent(_ agent: AgentProfile?, for chat: AIChatState) {
        let declined = ChatToolPolicy.declined(
            declinedDefault, choosing: agent?.id, for: chat.session.id,
            isUnsent: chat.session.messages.isEmpty, live: core.aiChats.live.lazy.map(\.session.id))
        if declined != declinedDefault { declinedDefault = declined }
        setAgent(agent, for: chat)
    }

    /// ⌘N keeps an empty chat as new, so one that said No Agent goes back to Settings' agent.
    func restoreDefault(in chat: AIChatState) {
        if declinedDefault.contains(chat.session.id) { declinedDefault.remove(chat.session.id) }
    }

    /// Settings' agent reads its folder off-main now, so a new chat's first send finds it cached.
    func warmChatAgent() {
        if let chatAgent { warmContext(for: chatAgent) }
    }
}

extension AIChatCoordinator {
    /// The agent an unbound chat shows is bound once the message went, never on a refused send.
    func sendBindingAgent(_ input: String, in chat: AIChatState) -> Bool {
        let id = chat.session.id
        let shown = agents.store.agent(forChat: id) == nil ? agents.agent(for: chat) : nil
        // An edited question takes its own place and every reply after it before it goes.
        workspace.applyEdit(in: chat)
        guard send(input, in: chat) else { return false }
        if let shown { agents.setAgent(shown, for: chat) }
        if agents.declinedDefault.contains(id) { agents.declinedDefault.remove(id) }
        return true
    }
}
