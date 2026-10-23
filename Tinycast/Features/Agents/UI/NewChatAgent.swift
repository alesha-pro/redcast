import Foundation

/// A chat before its first message: AI Chat's agent from Settings and a chat's own No Agent.
extension AgentCoordinator {
    /// Settings' pick for AI Chat's new chats, native or ACP, while AI is on and the agent exists.
    var chatAgent: AgentProfile? {
        ChatToolPolicy.windowAgent(
            picked: chatDefault.agentID, among: agents.lazy.map(\.id), aiEnabled: core.settings.aiEnabled
        ).flatMap(store.agent(id:))
    }

    /// The composer's or ⌘K's pick; No Agent on an unsent chat keeps Settings' agent out of it too.
    func chooseAgent(_ agent: AgentProfile?, for chat: AIChatState) {
        let id = chat.session.id
        if ChatToolPolicy.declines(agent?.id, isUnsent: chat.session.messages.isEmpty) {
            declinedDefault.insert(id)
        } else if declinedDefault.contains(id) {
            declinedDefault.remove(id)
        }
        setAgent(agent, for: chat)
    }
}

extension AIChatCoordinator {
    /// The agent an unbound chat shows is bound once the message went, never on a refused send.
    func sendBindingAgent(_ input: String, in chat: AIChatState) -> Bool {
        let id = chat.session.id
        let shown = agents.store.agent(forChat: id) == nil ? agents.agent(for: chat) : nil
        guard send(input, in: chat) else { return false }
        if let shown { agents.setAgent(shown, for: chat) }
        if agents.declinedDefault.contains(id) { agents.declinedDefault.remove(id) }
        return true
    }
}
