import Foundation

/// The shared prompt's last lines: the local time, then a plain chat's tools or how to search.
enum ChatBriefing {
    /// To the quarter hour, so a provider's cached prompt changes four times an hour, not per turn.
    static let clockStep: TimeInterval = 15 * 60
    static let mcpTools = "the MCP server tools in your tool list"

    /// Where Web Search is turned on, and its menu item's title in the language the user reads.
    struct SearchSwitch: Equatable, Sendable {
        let surface: ChatToolPolicy.Surface
        let title: String
    }

    static func text(
        now: Date, timeZone: TimeZone, tools: [String], serverTools: Bool, searchSwitch: SearchSwitch?
    ) -> String {
        var lines = [clock(now: now, timeZone: timeZone)]
        let offered = tools + (serverTools ? [mcpTools] : [])
        if !offered.isEmpty {
            lines.append("Tools you can call in this chat: \(offered.joined(separator: ", ")).")
        }
        if tools.contains(WebSearchTool.name) {
            lines.append(liveFacts)
        } else if let searchSwitch {
            lines.append(searchOff(searchSwitch, hasOtherTools: !offered.isEmpty))
        }
        return lines.joined(separator: "\n")
    }

    static func clock(now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        let start = Date(
            timeIntervalSince1970: (now.timeIntervalSince1970 / clockStep).rounded(.down) * clockStep)
        let weekday = calendar.weekdaySymbols[(day.weekday ?? 1) - 1]
        let date = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return "Local time: \(weekday), \(date), between \(time(start, in: calendar)) and "
            + "\(time(start.addingTimeInterval(clockStep), in: calendar)), \(timeZone.identifier) "
            + "(UTC\(offset(timeZone.secondsFromGMT(for: now))))."
    }

    static let liveFacts = """
        Live or recent facts (weather, prices and rates, news, scores, schedules) are not in your \
        training: call \(WebSearchTool.name), then \(WebPageTool.name) on the best result, and answer \
        from what the page says. If the page lacks what you need (some draw their figures with \
        scripts), read another result rather than guessing or sending the user to a website.
        """

    /// Other tools may still reach the web, so the switch is named only for what they can't.
    static func searchOff(_ searchSwitch: SearchSwitch, hasOtherTools: Bool) -> String {
        let place =
            switch searchSwitch.surface {
            case .quickAI: "with ⌘K → “\(searchSwitch.title)”"
            case .window: "from the + menu beside the message field → “\(searchSwitch.title)”"
            }
        let need =
            hasOtherTools
            ? "Built-in web search is off in this chat. When a question needs live data (weather, "
                + "prices, news, schedules) and none of your tools can look it up"
            : "You cannot search the web in this chat. When a question needs live data (weather, "
                + "prices, news, schedules)"
        return need + ", say in one line that the user can turn on web search \(place) and ask "
            + "again, then answer what you can without inventing current figures."
    }

    private static func time(_ date: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func offset(_ seconds: Int) -> String {
        let minutes = abs(seconds) / 60
        return (seconds < 0 ? "-" : "+") + String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
