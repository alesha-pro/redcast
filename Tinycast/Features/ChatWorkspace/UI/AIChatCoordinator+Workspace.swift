import Foundation

/// Fork: AI Chat's coordinator is the workspace's host; everything here routes to what it has.
extension AIChatCoordinator: ChatWorkspaceHost {
    func closeWindow() {
        _ = closeWindowIfKey()
    }

    func newChat(agentID: UUID?) {
        newChat()
        guard let agentID, let agent = agents.agents.first(where: { $0.id == agentID }) else { return }
        agents.chooseAgent(agent, for: chats.window)
    }

    func confirm(title: String, message: String, symbol: String, confirmTitle: String) async -> Bool {
        await AppCore.shared.confirm(
            title: title, message: message, symbol: symbol, confirmTitle: confirmTitle)
    }

    func showMessage(_ message: String) {
        AppCore.shared.showMessage(message)
    }

    func forgetChat(id: UUID) {
        AppCore.shared.chatGPTSubscription.turns.discardConversation(id: id)
        agents.chatDeleted(id)
    }

    var agentChoices: [ChatAgentChoice] {
        agents.agents.map { ChatAgentChoice(id: $0.id, name: $0.name, symbol: $0.symbol, hue: $0.hue) }
    }

    func agentID(ofChat id: UUID) -> UUID? {
        agents.store.agent(forChat: id)?.id
    }

    func bindAgent(_ id: UUID?, toChat chat: UUID) {
        agents.store.setAgent(id, forChat: chat)
    }

    var workspace: ChatWorkspaceCoordinator { AppCore.shared.chatWorkspace }
}
