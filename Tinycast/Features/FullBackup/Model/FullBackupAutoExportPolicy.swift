import Foundation

/// When a quit exports, what the file is called, and which older ones go.
enum FullBackupAutoExportPolicy {
    static let prefix = "Tinycast-Auto-"
    static let dayChoices = [1, 3, 7, 14, 30]
    static let keepChoices = [3, 5, 10, 20]

    static func isDue(lastExport: Date?, now: Date, days: Int) -> Bool {
        guard let lastExport else { return true }
        return now.timeIntervalSince(lastExport) >= Double(max(days, 1)) * 86_400
    }

    /// Sortable by name, so pruning needs no file dates.
    static func fileName(at date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d-%02d-%02d-%02d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return "\(prefix)\(stamp).tinycast"
    }

    /// Only files this policy named are ever pruned; anything else in the folder is the user's.
    static func pruned(_ names: [String], keeping count: Int) -> [String] {
        let ours = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".tinycast") }.sorted(by: >)
        return Array(ours.dropFirst(max(count, 1)))
    }
}
