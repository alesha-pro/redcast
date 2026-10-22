import Foundation

/// When a schedule repeats: a time each day, each working day, or every few hours.
struct AgentScheduleRule: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case daily, weekdays, everyHours }

    static let hourChoices = [1, 2, 3, 4, 6, 8, 12]

    var kind: Kind
    /// Minutes after local midnight: the time for daily and weekdays, the anchor for every N hours.
    var minuteOfDay: Int
    /// Every N hours only; a divisor of 24, so each day repeats the same times.
    var hours = 1

    /// The local times it fires at, as minutes after midnight, ascending.
    var minutesOfDay: [Int] {
        guard kind == .everyHours else { return [minuteOfDay] }
        let step = hours * 60
        return (0..<(24 / hours)).map { (minuteOfDay % step) + $0 * step }
    }

    var isValid: Bool {
        (0..<1_440).contains(minuteOfDay) && (kind != .everyHours || Self.hourChoices.contains(hours))
    }
}

enum AgentScheduleCatchUp: String, Codable, CaseIterable, Sendable {
    /// Missed occurrences collapse into one run, after the post-wake settle.
    case once
    /// Missed occurrences are dropped; the next one runs on time.
    case skip
}

/// A recurring task for one agent; it runs only while Tinycast is open.
struct AgentSchedule: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var agentID: UUID
    var name: String
    var prompt: String
    var rule: AgentScheduleRule
    var catchUp: AgentScheduleCatchUp
    /// A note the answer is appended to under a dated heading; nil keeps it to the chat.
    var noteTitle: String?
    var isEnabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(), agentID: UUID, name: String, prompt: String,
        rule: AgentScheduleRule = AgentScheduleRule(kind: .daily, minuteOfDay: 9 * 60),
        catchUp: AgentScheduleCatchUp = .once, noteTitle: String? = nil, isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.agentID = agentID
        self.name = name
        self.prompt = prompt
        self.rule = rule
        self.catchUp = catchUp
        self.noteTitle = noteTitle
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    /// Each run is its own chat, named so the sidebar tells one morning from the next.
    func runTitle(at date: Date, locale: Locale, timeZone: TimeZone) -> String {
        "\(name) · "
            + date.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone))
    }
}

enum AgentScheduleError: Error, LocalizedError, Equatable {
    case emptyName
    case emptyPrompt
    case invalidRule
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyName: return String(localized: "Give the schedule a name.")
        case .emptyPrompt: return String(localized: "Write what the agent should do.")
        case .invalidRule: return String(localized: "Choose when the schedule runs.")
        case .storageUnavailable: return String(localized: "Tinycast couldn't save its schedules.")
        }
    }
}

/// When schedules fire. Pure: every moment and the calendar come in, so the harness drives it.
enum AgentSchedulePolicy {
    /// Fired this late, a run still counts as on time rather than missed.
    static let onTime: TimeInterval = 5 * 60
    /// After launch or wake, a due run waits this long for the network to come back.
    static let settle: TimeInterval = 60

    enum Verdict: Equatable, Sendable {
        case run
        /// Missed under `.skip`: move the baseline to now without running.
        case skip
        case wait(until: Date)
    }

    /// The first occurrence strictly after `date`; nil only for an invalid rule.
    static func occurrence(after date: Date, rule: AgentScheduleRule, calendar: Calendar) -> Date? {
        guard rule.isValid else { return nil }
        return rule.minutesOfDay.compactMap { minute in
            var candidate = next(minute, after: date, calendar: calendar)
            guard rule.kind == .weekdays else { return candidate }
            // No locale rests seven days running, so a week of tries always lands on a working day.
            for _ in 0..<7 {
                guard let found = candidate, calendar.isDateInWeekend(found) else { break }
                candidate = next(minute, after: found, calendar: calendar)
            }
            return candidate.flatMap { calendar.isDateInWeekend($0) ? nil : $0 }
        }.min()
    }

    private static func next(_ minute: Int, after date: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(
            after: date, matching: DateComponents(hour: minute / 60, minute: minute % 60),
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    static func verdict(
        rule: AgentScheduleRule, catchUp: AgentScheduleCatchUp, baseline: Date, now: Date,
        notBefore: Date?, calendar: Calendar
    ) -> Verdict {
        // A clock set back must not postpone a day's run.
        let baseline = min(baseline, now)
        guard let due = occurrence(after: baseline, rule: rule, calendar: calendar) else {
            return .wait(until: .distantFuture)
        }
        if due > now { return .wait(until: due) }
        if now.timeIntervalSince(due) > onTime, catchUp == .skip { return .skip }
        if let notBefore, notBefore > now { return .wait(until: notBefore) }
        return .run
    }

    /// "Daily at 08:00", "Weekdays at 08:00", "Every 2 hours from 00:00".
    static func summary(of rule: AgentScheduleRule, calendar: Calendar, locale: Locale) -> String {
        let anchor = rule.kind == .everyHours ? rule.minuteOfDay % (rule.hours * 60) : rule.minuteOfDay
        let time = clockTime(anchor, calendar: calendar, locale: locale)
        switch rule.kind {
        case .daily: return String(localized: "Daily at \(time)")
        case .weekdays: return String(localized: "Weekdays at \(time)")
        case .everyHours: return String(localized: "Every \(rule.hours) hours from \(time)")
        }
    }

    /// A time of day in the reader's own style, read off a fixed day so no shift moves it.
    static func clockTime(_ minuteOfDay: Int, calendar: Calendar, locale: Locale) -> String {
        let reference = DateComponents(
            calendar: calendar, timeZone: calendar.timeZone, year: 2_001, month: 1, day: 1,
            hour: minuteOfDay / 60, minute: minuteOfDay % 60)
        guard let date = reference.date else { return "" }
        return date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: calendar.timeZone))
    }
}
