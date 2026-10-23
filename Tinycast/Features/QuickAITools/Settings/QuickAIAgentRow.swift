import SwiftUI

/// Settings › AI › Agents: the agent Quick AI's new chats answer with, on the chat's model.
struct QuickAIAgentRow: View {
    @Environment(AppCore.self) private var core

    var body: some View {
        AgentDefaultPicker(agents: core.agentCoordinator.quickAIAgents, agentID: agentBinding) {
            SettingsRowTitle(.aiAgents, "Quick AI answers with")
            Text(
                """
                New Quick AI chats run on this agent, with its folder, instructions, tools and \
                permissions. ⌘K in Quick AI switches it for one chat.
                """)
        }
    }

    /// A deleted agent, or one moved onto its own CLI, reads as No Agent, which is what answers.
    private var agentBinding: Binding<UUID?> {
        Binding(
            get: { core.agentCoordinator.quickAIAgent?.id },
            set: { core.agentCoordinator.quickAIDefault.agentID = $0 })
    }
}
