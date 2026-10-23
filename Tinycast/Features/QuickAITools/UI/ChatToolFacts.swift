import Foundation

/// A chat as `ChatToolPolicy` reads it, and what follows from it for the prompt and the switch.
extension AIChatCoordinator {
    func toolFacts(for chat: AIChatState) -> ChatToolPolicy.Facts {
        let can = capabilities(for: chat)
        var runsLoop = false
        if case .api? = model(for: chat) { runsLoop = true }
        return ChatToolPolicy.Facts(
            surface: agents.surface(of: chat), runsTinycastLoop: runsLoop, callsTools: can.tools,
            searches: can.webSearch, hasAgent: agents.agent(for: chat) != nil,
            webSearchOn: aiSettings.webSearchEnabled)
    }

    /// Read when a turn is sent, so the time is the send's and the tools are the turn's.
    func briefing(for chat: AIChatState, tools: [String]) -> String {
        let hint = ChatToolPolicy.searchHint(toolFacts(for: chat))
        return ChatBriefing.text(
            now: Date(), timeZone: .current, tools: tools,
            searchSwitch: hint.map { .init(surface: $0, title: String(localized: "Web Search")) })
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
