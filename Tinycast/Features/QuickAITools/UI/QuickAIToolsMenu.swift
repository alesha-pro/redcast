import Foundation

/// Quick AI's ⌘K rows for its tools: the Web Search switch and the agent that answers this chat.
@MainActor
enum QuickAIToolsMenu {
    static func items(for chat: AIChatState, chats: AIChatCoordinator) -> [PopoverMenuItem] {
        var items: [PopoverMenuItem] = []
        if ChatToolPolicy.offersSearchSwitch(chats.toolFacts(for: chat)) {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Web Search"),
                    icon: chats.aiSettings.webSearchEnabled ? .symbol("checkmark") : .blank,
                    startsSection: true
                ) {
                    chats.toggleWebSearch()
                })
        }
        let agents = chats.agents
        let current = agents.agent(for: chat)
        // An ACP agent is never offered here, but a chat opened from history may already have one.
        let offered = agents.quickAIAgents + [current].compactMap { $0?.runtime == nil ? nil : $0 }
        guard !offered.isEmpty else { return items }
        items.append(
            PopoverMenuItem(
                title: String(localized: "No Agent"), icon: current == nil ? .symbol("checkmark") : .blank,
                sectionTitle: String(localized: "Answer with"), startsSection: true
            ) {
                agents.chooseQuickAIAgent(nil, for: chat)
            })
        for agent in offered {
            items.append(
                PopoverMenuItem(
                    title: agent.name, icon: current?.id == agent.id ? .symbol("checkmark") : .blank
                ) {
                    agents.chooseQuickAIAgent(agent, for: chat)
                })
        }
        return items
    }
}
