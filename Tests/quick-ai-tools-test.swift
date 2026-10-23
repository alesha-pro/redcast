import Foundation

@main
@MainActor
struct QuickAIToolsTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        theClock()
        theBriefing()
        offeringInQuickAI()
        offeringElsewhere()
        whichAgentAnswers()
        theSettingPersists()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Fixtures

    static let moscow = TimeZone(identifier: "Europe/Moscow")!

    /// A wall-clock time in a zone, so every case reads as the local time it describes.
    static func date(_ text: String, in zone: TimeZone) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }

    static let webTools = [WebSearchTool.name, WebPageTool.name]

    static func facts(
        _ surface: ChatToolPolicy.Surface = .quickAI, loop: Bool = true, tools: Bool = true,
        searches: Bool = true, agent: Bool = false, on: Bool, servers: Bool = false
    ) -> ChatToolPolicy.Facts {
        ChatToolPolicy.Facts(
            surface: surface, runsTinycastLoop: loop, callsTools: tools, searches: searches,
            hasAgent: agent, webSearchOn: on, hasToolServers: servers)
    }

    static func briefing(
        _ facts: ChatToolPolicy.Facts, at now: Date, title: String = "Web Search"
    ) -> String {
        ChatBriefing.text(
            now: now, timeZone: moscow, tools: ChatToolPolicy.namedTools(facts),
            serverTools: ChatToolPolicy.mentionsServerTools(facts),
            searchSwitch: ChatToolPolicy.searchHint(facts).map { .init(surface: $0, title: title) })
    }

    // MARK: - The clock

    static func theClock() {
        let now = date("2026-10-23 14:37:12", in: moscow)
        expect(
            ChatBriefing.clock(now: now, timeZone: moscow)
                == "Local time: Friday, 2026-10-23, between 14:30 and 14:45, Europe/Moscow (UTC+03:00).",
            "the clock names the weekday, the date, its quarter hour and the zone with its offset")
        expect(
            ChatBriefing.clock(now: date("2026-10-23 14:30:00", in: moscow), timeZone: moscow)
                == ChatBriefing.clock(now: date("2026-10-23 14:44:59", in: moscow), timeZone: moscow),
            "every turn in one quarter hour sends the same prompt, so a provider's cache still hits")
        expect(
            ChatBriefing.clock(now: date("2026-10-23 14:45:00", in: moscow), timeZone: moscow)
                .contains("between 14:45 and 15:00"),
            "a quarter hour starts on its own minute")
        expect(
            ChatBriefing.clock(now: date("2026-10-23 23:52:00", in: moscow), timeZone: moscow)
                .contains("2026-10-23, between 23:45 and 00:00"),
            "the last quarter of a day keeps its date and ends at midnight")
        let newYork = TimeZone(identifier: "America/New_York")!
        expect(
            ChatBriefing.clock(now: date("2026-10-23 09:05:00", in: newYork), timeZone: newYork)
                == "Local time: Friday, 2026-10-23, between 09:00 and 09:15, America/New_York (UTC-04:00).",
            "a zone west of Greenwich has a negative offset, daylight time included")
        let kathmandu = TimeZone(identifier: "Asia/Kathmandu")!
        expect(
            ChatBriefing.clock(now: date("2026-10-24 06:52:00", in: kathmandu), timeZone: kathmandu)
                .contains("Saturday, 2026-10-24, between 06:45 and 07:00, Asia/Kathmandu (UTC+05:45)"),
            "a zone off the hour still gets local quarter hours")
    }

    // MARK: - The briefing

    static func theBriefing() {
        let now = date("2026-10-23 14:37:12", in: moscow)
        let searching = briefing(facts(on: true), at: now)
        expect(
            searching.hasPrefix(ChatBriefing.clock(now: now, timeZone: moscow)),
            "the briefing opens with the clock")
        expect(
            searching.contains("Tools you can call in this chat: web_search, read_page."),
            "the tools a turn offers are named")
        expect(
            searching.contains("call web_search, then read_page on the best result")
                && searching.contains("weather"),
            "live facts are sent through a search and a read of what it found")
        expect(
            searching.contains("lacks what you need") && searching.contains("read another result"),
            "a page without the figures sends the model on to another result")
        expect(!searching.contains("cannot search"), "a chat that searches is not told it cannot")

        // The owner's case: Quick AI on an API model, Web Search off, no agent, no MCP server.
        let quickOff = briefing(facts(on: false), at: now)
        expect(
            quickOff.contains("You cannot search the web in this chat")
                && quickOff.contains("with ⌘K → “Web Search”"),
            "Quick AI without search says in one line where its switch is")
        expect(!quickOff.contains("Tools you can call"), "and names no tools it does not have")
        expect(!quickOff.contains(WebPageTool.name), "and never tells it to read a page")

        let windowOff = briefing(facts(.window, on: false), at: now, title: "Поиск в интернете")
        expect(
            windowOff.contains("+ menu beside the message field → “Поиск в интернете”"),
            "AI Chat's own switch is the + menu, named as the user's menu spells it")

        let mcpOff = briefing(facts(on: false, servers: true), at: now)
        expect(
            mcpOff.contains("Tools you can call in this chat: \(ChatBriefing.mcpTools)."),
            "an MCP server's tools are pointed at in the list the request carries")
        expect(
            !mcpOff.contains("cannot search")
                && mcpOff.contains("Built-in web search is off")
                && mcpOff.contains("none of your tools can look it up")
                && mcpOff.contains("⌘K → “Web Search”"),
            "an MCP tool that can search is not contradicted; the switch is named only if none can")

        let mcpOn = briefing(facts(on: true, servers: true), at: now)
        expect(
            mcpOn.contains("web_search, read_page, \(ChatBriefing.mcpTools).")
                && mcpOn.contains(ChatBriefing.liveFacts),
            "with search on, Tinycast's tools are named beside the MCP ones")
        expect(
            !briefing(facts(on: true, servers: true), at: now).contains("__"),
            "no MCP tool is named: a turn's @server decides which ones the request carries")

        expect(
            briefing(facts(loop: false, tools: false, searches: false, on: true, servers: true), at: now)
                == ChatBriefing.clock(now: now, timeZone: moscow),
            "a route that can neither call tools nor search hears only the time")
        expect(
            briefing(facts(agent: true, on: false, servers: true), at: now)
                == ChatBriefing.clock(now: now, timeZone: moscow),
            "an agent's chat hears only the time: its own prompt describes its tools")
        expect(
            briefing(facts(loop: false, searches: false, on: false, servers: true), at: now)
                .contains("Tools you can call in this chat: \(ChatBriefing.mcpTools).")
                && !briefing(facts(loop: false, searches: false, on: false), at: now).contains("Tools"),
            "the Claude command hears of its MCP tools only when a server is on")
    }

    // MARK: - What is offered

    static func offeringInQuickAI() {
        // The owner's case: an OpenRouter model in Quick AI, Web search off, no agent.
        let off = facts(on: false)
        expect(ChatToolPolicy.offersSearchSwitch(off), "Quick AI on an API model offers ⌘K → Web Search")
        expect(!ChatToolPolicy.offersWebTools(off), "and sends no web tools while it is off")
        expect(ChatToolPolicy.searchHint(off) == .quickAI, "and its prompt says where the switch is")
        expect(ChatToolPolicy.namedTools(off).isEmpty, "and names none of the web tools")
        expect(
            ChatToolPolicy.mentionsServerTools(facts(on: false, servers: true)),
            "but points at an MCP server's tools when one is on")

        let on = facts(on: true)
        expect(ChatToolPolicy.offersWebTools(on), "switched on, web_search and read_page go out")
        expect(ChatToolPolicy.offersSearchSwitch(on), "and ⌘K can switch it off again")
        expect(ChatToolPolicy.searchHint(on) == nil, "and no hint is needed")
        expect(ChatToolPolicy.namedTools(on) == webTools, "and the prompt names both")

        for webSearch in [false, true] {
            let agent = facts(agent: true, on: webSearch)
            expect(
                !ChatToolPolicy.offersSearchSwitch(agent),
                "with an agent the ⌘K item is gone: its Web family decides (search \(webSearch))")
            expect(
                !ChatToolPolicy.offersWebTools(agent),
                "and the plain chat's web tools never ride beside the agent's (search \(webSearch))")
            expect(ChatToolPolicy.searchHint(agent) == nil, "and no hint points at a switch it ignores")
            expect(
                ChatToolPolicy.namedTools(agent).isEmpty
                    && !ChatToolPolicy.mentionsServerTools(facts(agent: true, on: webSearch, servers: true)),
                "and the agent's own prompt lists its tools")
        }
    }

    static func offeringElsewhere() {
        let onDevice = facts(loop: false, tools: false, searches: false, on: true)
        expect(
            !ChatToolPolicy.offersSearchSwitch(onDevice) && ChatToolPolicy.searchHint(onDevice) == nil,
            "the on-device model reaches nothing, so nothing points at a switch")
        expect(
            !ChatToolPolicy.mentionsServerTools(
                facts(loop: false, tools: false, searches: false, on: true, servers: true)),
            "and it has no tools to name")

        let codexOff = facts(loop: false, on: false)
        expect(ChatToolPolicy.offersSearchSwitch(codexOff), "Codex's own search follows the same switch")
        expect(!ChatToolPolicy.offersWebTools(codexOff), "but never gets Tinycast's web tools")
        expect(
            !ChatToolPolicy.offersWebTools(facts(loop: false, on: true)),
            "not even with the switch on, since it searches itself")
        expect(ChatToolPolicy.searchHint(codexOff) == .quickAI, "and off, it is told where the switch is")

        let claude = facts(loop: false, searches: false, on: true, servers: true)
        expect(
            !ChatToolPolicy.offersSearchSwitch(claude) && ChatToolPolicy.mentionsServerTools(claude)
                && ChatToolPolicy.namedTools(claude).isEmpty,
            "the Claude command has MCP tools to point at and no search to switch")

        let window = facts(.window, on: false)
        expect(ChatToolPolicy.searchHint(window) == .window, "AI Chat's hint names AI Chat's switch")
    }

    // MARK: - Which agent answers

    static func whichAgentAnswers() {
        let own = UUID()
        let quick = UUID()
        expect(
            ChatToolPolicy.agent(bound: own, quickAI: quick, surface: .quickAI, isUnsent: true, declined: false)
                == own,
            "a chat's own agent wins over Quick AI's")
        expect(
            ChatToolPolicy.agent(bound: own, quickAI: quick, surface: .quickAI, isUnsent: false, declined: true)
                == own,
            "and keeps answering once picked, whatever else was said")
        expect(
            ChatToolPolicy.agent(bound: nil, quickAI: quick, surface: .quickAI, isUnsent: true, declined: false)
                == quick,
            "a new Quick AI chat answers with Settings' agent")
        expect(
            ChatToolPolicy.agent(bound: nil, quickAI: quick, surface: .quickAI, isUnsent: false, declined: false)
                == nil,
            "a plain chat Quick AI resumes stays plain; only a first message binds the agent")
        expect(
            ChatToolPolicy.agent(bound: nil, quickAI: quick, surface: .quickAI, isUnsent: true, declined: true)
                == nil,
            "⌘K's No Agent keeps Settings' agent out of this chat")
        expect(
            ChatToolPolicy.agent(bound: nil, quickAI: quick, surface: .window, isUnsent: true, declined: false)
                == nil,
            "AI Chat's window never takes Quick AI's agent")
        expect(
            ChatToolPolicy.agent(bound: nil, quickAI: nil, surface: .quickAI, isUnsent: true, declined: false)
                == nil,
            "with none set, Quick AI answers with the chat's model")
    }

    // MARK: - The setting

    static func theSettingPersists() {
        let suite = "tinycast-quick-ai-tools-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        expect(QuickAISettingsStore(defaults: defaults).agentID == nil, "Quick AI starts with no agent")
        let agent = UUID()
        QuickAISettingsStore(defaults: defaults).agentID = agent
        expect(QuickAISettingsStore(defaults: defaults).agentID == agent, "the pick survives a relaunch")
        expect(
            defaults.string(forKey: AppSettingsKey.aiQuickAIAgent.rawValue) == agent.uuidString,
            "stored as the agent's id under its own key")
        QuickAISettingsStore(defaults: defaults).agentID = nil
        expect(
            defaults.object(forKey: AppSettingsKey.aiQuickAIAgent.rawValue) == nil,
            "No Agent leaves nothing behind")
        defaults.set("not an id", forKey: AppSettingsKey.aiQuickAIAgent.rawValue)
        expect(QuickAISettingsStore(defaults: defaults).agentID == nil, "an unreadable value means none")
    }
}
