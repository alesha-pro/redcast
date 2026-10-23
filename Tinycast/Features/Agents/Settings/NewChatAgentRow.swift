import SwiftUI

/// Settings › AI › Agents: the agent AI Chat's new chats start with, any the composer offers.
struct NewChatAgentRow: View {
    @Environment(AppCore.self) private var core

    var body: some View {
        AgentDefaultPicker(agents: core.agentCoordinator.agents, agentID: agentBinding) {
            SettingsRowTitle(.aiAgents, "Agent for new chats")
            Text(
                """
                New chats in AI Chat start with this agent, as if picked in the composer. The \
                composer switches it for one chat.
                """)
        }
    }

    /// A deleted agent reads as No Agent, which is what a new chat then starts with.
    private var agentBinding: Binding<UUID?> {
        Binding(
            get: { core.agentCoordinator.chatAgent?.id },
            set: { core.agentCoordinator.chatDefault.agentID = $0 })
    }
}
