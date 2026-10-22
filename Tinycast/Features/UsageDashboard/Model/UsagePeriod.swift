import Foundation

/// The span the Usage section sums over; view state only, never a preference.
enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: String(localized: "Day")
        case .week: String(localized: "Week")
        case .month: String(localized: "Month")
        }
    }

    private var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    /// The calendar's own boundaries, so a week starts on its first weekday and DST days are 23 h.
    func interval(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: component, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    }

    func step(_ date: Date, by count: Int, calendar: Calendar) -> Date {
        calendar.date(byAdding: component, value: count, to: date) ?? date
    }

    /// `DateInterval.contains` takes its end too, which is the next period's first instant.
    func isCurrent(_ interval: DateInterval, now: Date) -> Bool {
        interval.start <= now && now < interval.end
    }

    func title(
        of interval: DateInterval, now: Date, calendar: Calendar, locale: Locale = .current
    ) -> String {
        if isCurrent(interval, now: now) {
            switch self {
            case .day: return String(localized: "Today")
            case .week: return String(localized: "This Week")
            case .month: return String(localized: "This Month")
            }
        }
        let dates = Date.FormatStyle(
            date: .abbreviated, time: .omitted, locale: locale, calendar: calendar,
            timeZone: calendar.timeZone)
        switch self {
        case .day:
            if isCurrent(interval, now: step(now, by: -1, calendar: calendar)) {
                return String(localized: "Yesterday")
            }
            return interval.start.formatted(dates)
        case .week:
            let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
            let range = Date.IntervalFormatStyle(
                date: .abbreviated, time: .omitted, locale: locale, calendar: calendar,
                timeZone: calendar.timeZone)
            return (interval.start..<max(lastDay, interval.start)).formatted(range)
        case .month:
            return interval.start.formatted(
                Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                    .month(.wide).year())
        }
    }
}
