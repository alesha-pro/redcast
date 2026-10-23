import Foundation

/// What a chat is offered: Tinycast's web tools, the Web Search switch, and its starting agent.
enum ChatToolPolicy {
    enum Surface: Equatable, Sendable {
        case quickAI
        case window
    }

    /// One chat as its coordinator reads it, so every rule below is decided from values alone.
    struct Facts: Equatable, Sendable {
        var surface: Surface
        /// An API model, whose tools Tinycast's own loop runs, `web_search` and `read_page` too.
        var runsTinycastLoop: Bool
        /// The route calls tools at all; the on-device model and three of the CLIs do not.
        var callsTools: Bool
        /// The route searches while Web Search is on: an API model through Tinycast, Codex itself.
        var searches: Bool
        var hasAgent: Bool
        var webSearchOn: Bool
        /// An MCP server the chat's tools menu leaves on, whichever one a turn's `@server` names.
        var hasToolServers: Bool
    }

    /// Quick AI's ⌘K item and AI Chat's + menu toggle; an agent's Web family decides for its chat.
    static func offersSearchSwitch(_ facts: Facts) -> Bool {
        facts.searches && !facts.hasAgent
    }

    /// `web_search` and `read_page` from Tinycast: a plain chat on its loop, with the switch on.
    static func offersWebTools(_ facts: Facts) -> Bool {
        facts.runsTinycastLoop && facts.webSearchOn && offersSearchSwitch(facts)
    }

    /// Where the model may send someone whose question needs the web: the switch, while it is off.
    static func searchHint(_ facts: Facts) -> Surface? {
        offersSearchSwitch(facts) && !facts.webSearchOn ? facts.surface : nil
    }

    /// Tinycast's own tools a plain chat's prompt names; an agent's own prompt describes its tools.
    static func namedTools(_ facts: Facts) -> [String] {
        offersWebTools(facts) ? [WebSearchTool.name, WebPageTool.name] : []
    }

    /// MCP tools are pointed at, not named: a turn's `@server` decides which the request carries.
    static func mentionsServerTools(_ facts: Facts) -> Bool {
        facts.callsTools && facts.hasToolServers && !facts.hasAgent
    }

    /// The chat's own agent, else its surface's pick while it is unsent and nobody said none.
    static func agent<Agent>(
        bound: Agent?, quickAI: @autoclosure () -> Agent?, window: @autoclosure () -> Agent?,
        surface: Surface, isUnsent: Bool, declined: Bool
    ) -> Agent? {
        if let bound { return bound }
        guard isUnsent, !declined else { return nil }
        return surface == .quickAI ? quickAI() : window()
    }

    /// AI Chat's pick while AI is on and `lookup` still finds its agent; otherwise chats start plain.
    static func windowAgent<Agent>(picked: UUID?, aiEnabled: Bool, lookup: (UUID) -> Agent?) -> Agent? {
        guard aiEnabled, let picked else { return nil }
        return lookup(picked)
    }

    /// No Agent on an unsent chat keeps the pick out of it; another pick, or the chat gone, lets it in.
    static func declined(
        _ declined: Set<UUID>, choosing agent: UUID?, for chat: UUID, isUnsent: Bool,
        live: some Sequence<UUID>
    ) -> Set<UUID> {
        var kept = declined.intersection(live)
        if agent == nil && isUnsent { kept.insert(chat) } else { kept.remove(chat) }
        return kept
    }
}
