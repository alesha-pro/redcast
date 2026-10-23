import Foundation

/// What leads a turn's question: the turn's facts, and a reply the last turn could not finish.
struct AgentTurnLead: Equatable, Sendable {
    /// The time and the budget, in the question so the prompt above it stays cached.
    var opening: String?
    /// A reply that failed or was stopped, which history leaves out; it goes back before the question.
    var resuming: String?

    init(opening: String? = nil, resuming: String? = nil) {
        self.opening = opening
        self.resuming = resuming
    }

    /// The turn's facts in one line: the time to the minute, and how much the run may do.
    static func opening(now: Date, timeZone: TimeZone, budget: AgentRunBudget, effort: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: now)
        let weekday = calendar.weekdaySymbols[(parts.weekday ?? 1) - 1]
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        return "[Now: \(weekday) \(date) \(time), \(timeZone.identifier). \(effort): up to \(budget.rounds) "
            + "rounds of tool calls.]"
    }

    /// `Europe/Moscow (UTC+03:00)`, the zone the prompt names once.
    static func zone(_ timeZone: TimeZone, at now: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: now)
        let minutes = abs(seconds) / 60
        let offset = (seconds < 0 ? "-" : "+") + String(format: "%02d:%02d", minutes / 60, minutes % 60)
        return "\(timeZone.identifier) (UTC\(offset))"
    }

    func led(_ messages: [AIMessage]) -> [AIMessage] {
        guard var question = messages.lastIndex(where: { $0.role == .user }) else { return messages }
        var messages = messages
        if let resuming, question > 0, messages[question - 1].role == .user {
            messages.insert(AIMessage(role: .assistant, text: resuming), at: question)
            question += 1
        }
        guard let opening else { return messages }
        let asked = messages[question]
        messages[question] = AIMessage(
            role: .user, text: opening + "\n\n" + asked.text, images: asked.images, documents: asked.documents,
            audio: asked.audio)
        return messages
    }
}
