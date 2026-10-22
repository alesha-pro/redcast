import AppKit

/// One task sleeping toward the next due time: none while the Mac sleeps, re-armed when it wakes.
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
    /// How long the Mac has slept, counted from any fixed point; only its growth is read.
    private let slept: () -> Duration

    private var timer: Task<Void, Never>?
    private var observers: [NotificationToken] = []
    /// After launch or wake, nothing due runs before this.
    private var notBefore: Date?
    private var sleptAtLastApply: Duration

    init(
        store: AgentStore, start: @escaping (AgentSchedule) -> Start,
        now: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { .current },
        slept: @escaping () -> Duration = AgentScheduler.sleepMeter()
    ) {
        self.store = store
        self.start = start
        self.now = now
        self.calendar = calendar
        self.slept = slept
        sleptAtLastApply = slept()
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
        let slept = slept()
        // Whatever comes first after a sleep, the wake or a clock change or a run's end, settles.
        if settling || slept - sleptAtLastApply > .seconds(1) {
            notBefore = now.addingTimeInterval(AgentSchedulePolicy.settle)
        }
        sleptAtLastApply = slept
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
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.apply(settling: false)
        }
    }

    /// The Mac is going to sleep: nothing ticks until the wake re-arms.
    func suspend() {
        timer?.cancel()
        timer = nil
    }

    func stop() {
        timer?.cancel()
        timer = nil
        observers = []
        notBefore = nil
    }

    /// The continuous clock counts sleep and the suspending one does not; their gap is time asleep.
    nonisolated static func sleepMeter() -> () -> Duration {
        let total = ContinuousClock.now
        let awake = SuspendingClock.now
        return { total.duration(to: .now) - awake.duration(to: .now) }
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        observers = [
            observe(workspace, NSWorkspace.willSleepNotification) { $0.suspend() },
            observe(workspace, NSWorkspace.didWakeNotification) { $0.apply(settling: true) },
            observe(center, .NSSystemClockDidChange) { $0.apply(settling: false) },
            observe(center, .NSSystemTimeZoneDidChange) { $0.apply(settling: false) }
        ]
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        _ handler: @escaping @Sendable @MainActor (AgentScheduler) -> Void
    ) -> NotificationToken {
        NotificationToken(
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            }, center: center)
    }
}
