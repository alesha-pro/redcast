import Foundation

/// What a chat is offered: Tinycast's web tools, the Web Search switch, and Quick AI's agent.
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

    /// The chat's own agent, else Quick AI's while its chat is unsent and ⌘K has not said none.
    static func agent(
        bound: UUID?, quickAI: UUID?, surface: Surface, isUnsent: Bool, declined: Bool
    ) -> UUID? {
        if let bound { return bound }
        guard surface == .quickAI, isUnsent, !declined else { return nil }
        return quickAI
    }
}
