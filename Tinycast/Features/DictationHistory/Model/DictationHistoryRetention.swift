import Foundation

/// How long Dictation History keeps an entry; Off records nothing and keeps nothing.
enum DictationHistoryRetention: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case day = 1
    case week = 7
    case month = 30
    case quarter = 90
    case forever = -1

    static let standard = Self.month

    var id: Int { rawValue }

    var keepsHistory: Bool { self != .off }

    /// The oldest date kept at `now`; nil keeps every entry.
    func cutoff(now: Date) -> Date? {
        switch self {
        case .forever: nil
        case .off: .distantFuture
        case .day, .week, .month, .quarter: now.addingTimeInterval(-TimeInterval(rawValue) * 86_400)
        }
    }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .day: String(localized: "1 Day")
        case .week: String(localized: "7 Days")
        case .month: String(localized: "30 Days")
        case .quarter: String(localized: "90 Days")
        case .forever: String(localized: "Forever")
        }
    }
}
