import Foundation

/// Quick AI's agent: Settings' pick for a chat not sent yet, ⌘K's for the chat in front.
extension AgentCoordinator {
    /// Agents on the chat's model; an ACP agent keeps its pickers and its process to AI Chat.
    var quickAIAgents: [AgentProfile] {
        agents.filter { $0.runtime == nil }
    }

    /// Settings' pick while it still names an agent Quick AI may answer with.
    var quickAIAgent: AgentProfile? {
        quickAIDefault.agentID.flatMap(store.agent(id:)).flatMap { $0.runtime == nil ? $0 : nil }
    }

    func surface(of chat: AIChatState) -> ChatToolPolicy.Surface {
        core.aiChats.quickAI === chat ? .quickAI : .window
    }

    /// What Quick AI shows goes with a chat ⌘J moves, No Agent included, so the window agrees.
    func adoptQuickAIAgent(in chat: AIChatState) {
        guard store.agent(forChat: chat.session.id) == nil,
            !chat.session.messages.isEmpty || !chat.pendingAttachments.isEmpty
        else { return }
        chooseAgent(agent(for: chat), for: chat)
    }
}
