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

    /// A 25-hour day and a 31-day month both fit.
    static let maxSlices = 32

    /// Where each bar of the trend starts: the hours of a day, else the days of a week or month.
    func slices(of interval: DateInterval, calendar: Calendar) -> [Date] {
        let unit: Calendar.Component = self == .day ? .hour : .day
        var starts: [Date] = []
        var next = interval.start
        while next < interval.end, starts.count < Self.maxSlices {
            starts.append(next)
            // Counted from the start each time, so a short month or a DST day never drifts a bar.
            guard let following = calendar.date(byAdding: unit, value: starts.count, to: interval.start),
                following > next
            else { break }
            next = following
        }
        return starts
    }

    func sliceTitle(of start: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        return start.formatted(self == .day ? style.hour() : style.month(.abbreviated).day())
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
