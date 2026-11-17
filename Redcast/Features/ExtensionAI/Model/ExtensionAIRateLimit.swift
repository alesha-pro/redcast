import Foundation

/// Raycast's per-extension AI limit, kept in memory: a relaunch starts every window afresh.
struct ExtensionAIRateLimit: Sendable {
    static let perMinute = 10
    static let perHour = 100
    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 3_600

    private var stamps: [String: [Date]] = [:]

    /// Records an admitted request and returns nil, or how long until one would be admitted.
    mutating func admit(_ extensionName: String, at now: Date) -> TimeInterval? {
        let recent = (stamps[extensionName] ?? []).filter { now.timeIntervalSince($0) < Self.hour }
        stamps[extensionName] = recent
        let lastMinute = recent.filter { now.timeIntervalSince($0) < Self.minute }
        if lastMinute.count >= Self.perMinute, let oldest = lastMinute.min() {
            return oldest.addingTimeInterval(Self.minute).timeIntervalSince(now)
        }
        if recent.count >= Self.perHour, let oldest = recent.min() {
            return oldest.addingTimeInterval(Self.hour).timeIntervalSince(now)
        }
        stamps[extensionName] = recent + [now]
        return nil
    }
}
