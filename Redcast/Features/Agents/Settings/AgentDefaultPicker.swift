import SwiftUI

/// A Settings row picking the agent a surface's new chats start with: No Agent, then each agent.
struct AgentDefaultPicker<Title: View>: View {
    let agents: [AgentProfile]
    @Binding var agentID: UUID?
    @ViewBuilder let title: Title

    var body: some View {
        Picker(selection: $agentID) {
            Text("No Agent").tag(UUID?.none)
            ForEach(agents) { agent in
                Label {
                    Text(verbatim: agent.name)
                } icon: {
                    Image(nsImage: GlyphTile.menuImage(symbol: agent.symbol, hue: agent.hue))
                }
                .tag(Optional(agent.id))
            }
        } label: {
            title
        }
    }
}
