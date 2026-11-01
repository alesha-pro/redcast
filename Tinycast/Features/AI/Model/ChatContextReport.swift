import Foundation

/// What the context card lays out; history is counted in bytes, the unit the budget is kept in.
struct ChatContextReport: Equatable {
    let modelTitle: String
    let historyBytes: Int
    let budget: Int
    let sentMessages: Int
    let totalMessages: Int
    let stagedFiles: Int
    let stagedBytes: Int
    let usage: AIUsage?
    /// Fork: the model's window from the catalog, for a route that does not report its own.
    var knownWindow: Int?
    /// Fork: false on a plan, whose route may still report a price nobody is charged.
    var costApplies = true
    let systemPrompt: Bool
    let webSearch: Bool
    let toolServers: Int

    var window: Int? {
        (usage?.contextWindow ?? knownWindow).flatMap { $0 > 0 ? $0 : nil }
    }

    /// False when `fill` is Tinycast's history budget, which says nothing about the model's window.
    var fillsWindow: Bool {
        window != nil && (usage?.contextTokens != nil || historyBytes == 0)
    }

    var fill: Double {
        if fillsWindow, let window { return Double(usage?.contextTokens ?? 0) / Double(window) }
        return Double(historyBytes) / Double(max(budget, 1))
    }

    var accessibilitySummary: String {
        let percent = fill.formatted(.percent.precision(.fractionLength(0)))
        return fillsWindow
            ? String(localized: "Context \(percent), \(sentMessages) of \(totalMessages) messages sent")
            : String(localized: "History \(percent), \(sentMessages) of \(totalMessages) messages sent")
    }
}
