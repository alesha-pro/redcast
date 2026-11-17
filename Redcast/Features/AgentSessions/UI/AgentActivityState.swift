import Foundation
import Observation

/// What the agents' hooks reported; nothing ages on a timer, every read prunes first.
@MainActor
@Observable
final class AgentActivityState {
    private(set) var items: [AgentActivity] = []
    /// The last HUD per session and kind, so a quick waiting → working → waiting stays quiet.
    @ObservationIgnored private var announced: [String: Date] = [:]

    /// True while any item is working, waiting, or finished and not yet seen.
    var needsAttention: Bool { items.contains(where: \.needsAttention) }

    /// The entry it replaced and the one now stored; nil when a newer event already won.
    func apply(_ event: AgentEvent, resolved: AgentActivity, now: Date)
        -> (previous: AgentActivity?, current: AgentActivity)?
    {
        let previous = items.first { $0.id == resolved.id }
        let updated = AgentActivityPolicy.apply(event, resolved: resolved, to: items, now: now)
        guard let current = updated.first(where: { $0.id == resolved.id }), current.status == event.status,
            current.updatedAt == resolved.updatedAt
        else {
            items = updated
            return nil
        }
        items = updated
        return (previous, current)
    }

    func prune(now: Date) {
        let pruned = AgentActivityPolicy.prune(items, now: now)
        if pruned != items { items = pruned }
        announced = announced.filter { now.timeIntervalSince($0.value) < AgentActivityPolicy.repeatWindow }
    }

    func lastAnnounced(_ id: AgentActivity.ID, kind: AgentHookEvent) -> Date? {
        announced[id + "|" + kind.rawValue]
    }

    func recordAnnouncement(_ id: AgentActivity.ID, kind: AgentHookEvent, at date: Date) {
        announced[id + "|" + kind.rawValue] = date
    }

    func markSeen(_ id: AgentActivity.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].seen else { return }
        items[index].seen = true
    }

    func markFinishedSeen() {
        for index in items.indices where items[index].status == .finished || items[index].status == .failed {
            items[index].seen = true
        }
    }

    func clearFinished() {
        items.removeAll { $0.status == .finished || $0.status == .failed || $0.status == .ended }
    }

    func removeAll() {
        items = []
        announced = [:]
    }
}
