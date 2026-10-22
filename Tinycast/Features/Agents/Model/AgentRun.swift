import Foundation

/// One unattended turn, keyed by its chat; what the indicator and the settings rows show.
struct AgentRun: Identifiable, Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case launcher
        /// `manual` is Run Now: announced like a launcher run, and the schedule's timing untouched.
        case schedule(UUID, manual: Bool)

        var scheduleID: UUID? {
            guard case .schedule(let id, _) = self else { return nil }
            return id
        }

        /// A HUD at its start and end; a schedule's own run stays quiet, so 3 a.m. stays dark.
        var announces: Bool {
            switch self {
            case .launcher: true
            case .schedule(_, let manual): manual
            }
        }
    }

    enum State: Equatable, Sendable {
        case running
        case waiting
        case done
        case failed(String)
    }

    let id: UUID
    let agentID: UUID
    let agentName: String
    let symbol: String
    /// The task's first line or the schedule's name, at most 80 characters.
    let title: String
    let origin: Origin
    let startedAt: Date
    var endedAt: Date?
    var state: State
    /// Requests refused by the policy or because nobody was at the Mac.
    var declined = 0
    /// What went wrong after the answer itself, such as a note that would not take it.
    var problem: String?
    var isSeen = false

    var isActive: Bool { state == .running || state == .waiting }

    var isFailed: Bool {
        guard case .failed = state else { return false }
        return true
    }

    /// Done only with a complete answer; otherwise why it ended, in the words its row shows.
    static func endState(complete: Bool, reply: String?, stoppedAfter minutes: Int?) -> State {
        if complete { return .done }
        if let minutes { return .failed(String(localized: "Stopped after \(minutes) minutes")) }
        // The reply's last line is where a failure says what went wrong.
        let line =
            reply?.split(whereSeparator: \.isNewline).last
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return .failed(String(localized: "The response ended unexpectedly.")) }
        return .failed(line.count > 120 ? String(line.prefix(119)) + "…" : line)
    }

    static let maxTitleLength = 80

    /// The first non-empty line, so a long task reads as a name in a menu row.
    static func title(for task: String) -> String {
        let line =
            task.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard line.count > maxTitleLength else { return line }
        return String(line.prefix(maxTitleLength - 1)) + "…"
    }
}

/// Recent unattended runs, newest first; finished ones are kept only until there are ten.
struct AgentRunLedger: Equatable, Sendable {
    enum Indicator: Equatable, Sendable {
        case hidden
        case waiting
        case running(Int)
        case failed
        case done
    }

    static let keptFinished = 10

    /// Newest first.
    private(set) var runs: [AgentRun] = []

    mutating func begin(_ run: AgentRun) {
        runs.insert(run, at: 0)
        trim()
    }

    mutating func update(_ id: UUID, _ change: (inout AgentRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[index])
        trim()
    }

    mutating func markFinishedSeen() {
        for index in runs.indices where !runs[index].isActive { runs[index].isSeen = true }
    }

    mutating func remove(_ id: UUID) {
        runs.removeAll { $0.id == id }
    }

    func run(_ id: UUID) -> AgentRun? {
        runs.first { $0.id == id }
    }

    func isBusy(agent: UUID) -> Bool {
        runs.contains { $0.agentID == agent && $0.isActive }
    }

    func isRunning(schedule: UUID) -> Bool {
        runs.contains { $0.origin.scheduleID == schedule && $0.isActive }
    }

    var activeCount: Int { runs.count(where: \.isActive) }

    /// Waiting beats running beats an unseen failure beats an unseen success.
    var indicator: Indicator {
        if runs.contains(where: { $0.state == .waiting }) { return .waiting }
        let active = activeCount
        if active > 0 { return .running(active) }
        if runs.contains(where: { $0.isFailed && !$0.isSeen }) { return .failed }
        if runs.contains(where: { $0.state == .done && !$0.isSeen }) { return .done }
        return .hidden
    }

    /// Active runs are never dropped; the oldest finished ones go first.
    private mutating func trim() {
        var finished = runs.count { !$0.isActive }
        while finished > Self.keptFinished, let oldest = runs.lastIndex(where: { !$0.isActive }) {
            runs.remove(at: oldest)
            finished -= 1
        }
    }
}

/// How one request in a chat is treated: as always, asked with Return on refusal, or refused.
enum AgentConsentMode: Equatable, Sendable {
    case foreground
    case ask
    case decline

    /// Someone touched the Mac this recently, so a dialog has a reader.
    static let presenceWindow: TimeInterval = 120

    static func decide(
        isUnattended: Bool, consent: AgentBackgroundConsent, idleSeconds: TimeInterval
    ) -> Self {
        guard isUnattended else { return .foreground }
        guard consent == .ask, idleSeconds < presenceWindow else { return .decline }
        return .ask
    }
}

/// How one agent question is put; decided when it is asked and again when its turn comes.
enum AgentConsentPlan: Equatable, Sendable {
    /// A chat someone started: Tinycast comes forward and Return allows, as it always has.
    case inFront
    /// A run nobody started, with someone at the Mac: nothing comes forward, and Return refuses.
    case quiet(refusal: Int)
    /// Refused unasked, and counted on the run's row.
    case refused

    init(mode: AgentConsentMode, refusal: Int?) {
        switch mode {
        case .foreground: self = .inFront
        case .ask: self = refusal.map { .quiet(refusal: $0) } ?? .refused
        case .decline: self = .refused
        }
    }

    var activates: Bool { self == .inFront }

    /// The answer Return picks.
    var defaultIndex: Int {
        guard case .quiet(let refusal) = self else { return 0 }
        return refusal
    }

    /// An unattended question left unanswered or refused counts; a chat's own never does.
    func countsDecline(answer: Int?) -> Bool {
        switch self {
        case .inFront: false
        case .quiet(let refusal): answer == nil || answer == refusal
        case .refused: true
        }
    }
}

extension AgentRunMode {
    /// A run set to decline never stops to ask, so the toolset refuses before any dialog is built.
    static func turn(in chatID: UUID, isUnattended: Bool, consent: AgentBackgroundConsent) -> Self {
        isUnattended && consent == .decline ? .unattended(chatID) : .chat(chatID)
    }
}

/// What background agents keep alive: nothing at all until a schedule or a banner needs it.
struct AgentBackgroundNeeds: Equatable, Sendable {
    /// One sleeping task and its sleep, wake, clock and time-zone observers.
    var scheduler = false
    var notifier = false

    var any: Bool { scheduler || notifier }

    static func of(aiEnabled: Bool, agents: [AgentProfile], schedules: [AgentSchedule]) -> Self {
        guard aiEnabled else { return Self() }
        let known = Set(agents.map(\.id))
        return Self(
            scheduler: schedules.contains { $0.isEnabled && known.contains($0.agentID) },
            notifier: agents.contains { $0.backgroundPolicy.notifies })
    }
}

/// The dated section a scheduled run appends to a note.
enum AgentNoteEntry {
    static let maxAnswerBytes = 64 * 1_024

    static func block(
        heading: String, at date: Date, answer: String, locale: Locale, timeZone: TimeZone
    ) -> String {
        let stamp = date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone))
        let body = capped(answer.trimmingCharacters(in: .whitespacesAndNewlines))
        return "## \(heading) — \(stamp)\n\n\(body)"
    }

    /// Exactly one blank line between what was there and the new section.
    static func appending(_ block: String, to source: String) -> String {
        let kept = String(source.reversed().drop(while: \.isNewline).reversed())
        return (kept.isEmpty ? "" : kept + "\n\n") + block + "\n"
    }

    private static func capped(_ answer: String) -> String {
        guard answer.utf8.count > maxAnswerBytes else { return answer }
        let marker = "\n\n" + String(localized: "… The full answer is in AI Chat.")
        var kept = ""
        var used = 0
        for character in answer {
            let size = character.utf8.count
            guard used + size <= maxAnswerBytes - marker.utf8.count else { break }
            kept.append(character)
            used += size
        }
        return kept + marker
    }
}

/// Told to a native agent's model while its turn runs unattended. Model-facing, so not localized.
enum AgentBackgroundBriefing {
    static let text = """
        This turn runs in the background: nobody is watching and nobody can answer a question \
        until it ends. Do the task with what you have, then finish with a short report: what you \
        did, what you found, and what is left for the user. A refused request means the user was \
        not asked; say what you would have done.
        """

    /// An ACP agent's equivalent, leading each prompt of an unattended turn after its context.
    static let acp = """
        # Running unattended

        This turn runs in the background, started by Tinycast rather than typed by the user: nobody \
        may be at the Mac, and nobody can answer a question until it ends. Permission requests are \
        declined unless someone at the Mac answers them, so do what you can without them. Finish \
        with the result as your final message: what you did, what you found, and what is left for \
        the user. If a request was declined, say what you would have done.
        """
}
