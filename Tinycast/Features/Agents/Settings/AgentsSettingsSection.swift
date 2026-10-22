import SwiftUI

/// The AI pane's list of agents: start a chat with one, edit it, or add another.
struct AgentsSettingsSection: View {
    @Environment(AppCore.self) private var core
    @State private var editing: AgentEditRequest?

    var body: some View {
        let agents = core.agentCoordinator
        Section {
            ForEach(agents.agents) { agent in
                SettingsRow(title: agent.name, subtitle: agent.directory) {
                    SymbolImage(name: agent.symbol, size: Theme.Size.quickActionHeaderIcon)
                        .frame(width: Theme.Size.settingsRowIcon)
                } trailing: {
                    Button("New Chat") { agents.startChat(with: agent) }
                    Button("Edit…") { editing = AgentEditRequest(agent: agent) }
                }
            }
            Button {
                editing = AgentEditRequest(agent: nil)
            } label: {
                SettingsRowTitle(.aiAgents, "Add Agent")
            }
        } header: {
            SettingsSectionHeader(.aiAgents)
        } footer: {
            Text(
                """
                An agent lives in one folder: its chats read that folder's AGENTS.md and skills, and \
                its tools work there. Choose one for a chat from the composer.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .settingsEditorPanel(item: $editing) { request in
            AgentEditorPanel(request: request)
        }
    }
}

struct AgentEditRequest: Identifiable {
    let id = UUID()
    let agent: AgentProfile?
}
