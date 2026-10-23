import Foundation

/// A chat as `ChatToolPolicy` reads it, and what follows from it for the prompt and the switch.
extension AIChatCoordinator {
    func toolFacts(for chat: AIChatState) -> ChatToolPolicy.Facts {
        let can = capabilities(for: chat)
        var runsLoop = false
        if case .api? = model(for: chat) { runsLoop = true }
        let scope = chat.toolScope
        return ChatToolPolicy.Facts(
            surface: agents.surface(of: chat), runsTinycastLoop: runsLoop, callsTools: can.tools,
            searches: can.webSearch, hasAgent: agents.agent(for: chat) != nil,
            webSearchOn: aiSettings.webSearchEnabled,
            hasToolServers: mcpServers.contains { scope.allows($0.slug) && $0.trust != .never })
    }

    /// Read when a turn is sent, so the time is the send's; an agent's own loop leads its turn with it.
    func briefing(for chat: AIChatState) -> String? {
        let facts = toolFacts(for: chat)
        guard !(facts.hasAgent && facts.runsTinycastLoop && !agents.runsOwnRuntime(chat)) else { return nil }
        return ChatBriefing.text(
            now: Date(), timeZone: .current, tools: ChatToolPolicy.namedTools(facts),
            serverTools: ChatToolPolicy.mentionsServerTools(facts),
            searchSwitch: ChatToolPolicy.searchHint(facts).map {
                .init(surface: $0, title: String(localized: "Web Search"))
            })
    }

    /// Quick AI's ⌘K Web Search: the + menu's setting, said in a HUD since no pill shows it there.
    func toggleWebSearch() {
        aiSettings.webSearchEnabled.toggle()
        agents.core.showMessage(
            aiSettings.webSearchEnabled
                ? String(localized: "Web search is on") : String(localized: "Web search is off"),
            tone: .neutral)
    }
}
