import AppKit

/// One sleeping task for the next due schedule, re-armed on wake, clock and time-zone changes.
@MainActor
final class AgentScheduler {
    enum Start {
        case started
        /// The agent is mid-run; its end applies again, so the schedule waits rather than spins.
        case busy
        case failed
    }

    private let store: AgentStore
    private let start: (AgentSchedule) -> Start
    private let now: () -> Date
    private let calendar: () -> Calendar

    private var timer: Task<Void, Never>?
    private var observers: [NotificationToken] = []
    /// After launch or wake, nothing due runs before this.
    private var notBefore: Date?

    init(
        store: AgentStore, start: @escaping (AgentSchedule) -> Start,
        now: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { .current }
    ) {
        self.store = store
        self.start = start
        self.now = now
        self.calendar = calendar
    }

    isolated deinit {
        timer?.cancel()
    }

    /// Whether a task sleeps toward a due time; false whenever no enabled schedule is waiting.
    var isArmed: Bool { timer != nil }

    var isObserving: Bool { !observers.isEmpty }

    /// Fires what is due and arms for the next; `settling` delays a due run after launch or wake.
    func apply(settling: Bool) {
        timer?.cancel()
        timer = nil
        let now = now()
        if settling { notBefore = now.addingTimeInterval(AgentSchedulePolicy.settle) }
        if let notBefore, notBefore <= now { self.notBefore = nil }
        let enabled = store.schedules.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            stop()
            return
        }
        let calendar = calendar()
        var next: Date?
        for schedule in enabled {
            let verdict = AgentSchedulePolicy.verdict(
                rule: schedule.rule, catchUp: schedule.catchUp, baseline: store.baseline(for: schedule),
                now: now, notBefore: notBefore, calendar: calendar)
            switch verdict {
            case .run:
                guard start(schedule) != .busy else { continue }
                store.setBaseline(now, forSchedule: schedule.id)
            case .skip:
                store.setBaseline(now, forSchedule: schedule.id)
            case .wait(let until):
                next = min(next ?? until, until)
                continue
            }
            if let due = AgentSchedulePolicy.occurrence(after: now, rule: schedule.rule, calendar: calendar) {
                next = min(next ?? due, due)
            }
        }
        observe()
        guard let next else { return }
        let delay = max(0, next.timeIntervalSince(now))
        // `Task.sleep` keeps counting through sleep, so a deadline passed asleep fires on wake.
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.apply(settling: false)
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        observers = []
        notBefore = nil
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let wake: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.apply(settling: true) }
        }
        let clock: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.apply(settling: false) }
        }
        observers = [
            NotificationToken(
                workspace.addObserver(
                    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: wake),
                center: workspace),
            NotificationToken(
                center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main, using: clock),
                center: center),
            NotificationToken(
                center.addObserver(
                    forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: clock),
                center: center)
        ]
    }
}
