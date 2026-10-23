import Foundation

/// Quick AI's agent: Settings' pick for a chat not sent yet, ⌘K's for the chat in front.
extension AgentCoordinator {
    /// Agents on the chat's model; an ACP agent keeps its pickers and its process to AI Chat.
    var quickAIAgents: [AgentProfile] {
        agents.filter { $0.runtime == nil }
    }

    /// Settings' pick while it still names an agent Quick AI may answer with.
    var quickAIAgent: AgentProfile? {
        quickAISettings.agentID.flatMap(store.agent(id:)).flatMap { $0.runtime == nil ? $0 : nil }
    }

    func surface(of chat: AIChatState) -> ChatToolPolicy.Surface {
        core.aiChats.quickAI === chat ? .quickAI : .window
    }

    /// The agent Quick AI shows becomes the chat's own, so its later turns and AI Chat keep it.
    func adoptQuickAIAgent(in chat: AIChatState) {
        guard store.agent(forChat: chat.session.id) == nil, let agent = agent(for: chat) else { return }
        setAgent(agent, for: chat)
    }

    /// ⌘K's choice for this chat; No Agent on an unsent one also keeps Settings' agent out of it.
    func chooseQuickAIAgent(_ agent: AgentProfile?, for chat: AIChatState) {
        quickAIDeclined = agent == nil && chat.session.messages.isEmpty ? chat.session.id : nil
        setAgent(agent, for: chat)
    }
}
