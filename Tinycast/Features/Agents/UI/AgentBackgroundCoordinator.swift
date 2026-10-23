import AppKit
import Observation

/// Unattended agent runs: a parked chat per run, its indicator, consent, delivery and schedules.
@MainActor
@Observable
final class AgentBackgroundCoordinator {
    static let maxConcurrent = 3

    enum Refusal: Error {
        case aiOff
        case busy(String)
        case full
        case failed(String)
        /// A schedule's due run past the day's spend cap.
        case capped
    }

    private(set) var ledger = AgentRunLedger()

    @ObservationIgnored private let store: AgentStore
    @ObservationIgnored private unowned let core: AppCore
    /// Only while running; the chat itself is parked in AI Chat, which saves it as it goes.
    @ObservationIgnored private var chats: [UUID: AIChatState] = [:]
    @ObservationIgnored private var watchdogs: [UUID: Task<Void, Never>] = [:]
    /// Runs the watchdog stopped, with the limit it stopped them at.
    @ObservationIgnored private var timedOut: [UUID: Int] = [:]
    /// Runs the spend cap stopped, with the cap they passed.
    @ObservationIgnored private var cappedAt: [UUID: Double] = [:]
    @ObservationIgnored private var scheduleOf: [UUID: AgentSchedule] = [:]
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var notifier: AgentRunNotifier?
    @ObservationIgnored private var scheduler: AgentScheduler?
    /// Called once nothing runs, shows or waits for a due time, so the owner can let this go.
    @ObservationIgnored var onIdle: (() -> Void)?

    /// Any input at all; `.null` would measure nothing a person does.
    private static let anyInput = CGEventType(rawValue: ~0)

    init(store: AgentStore, core: AppCore) {
        self.store = store
        self.core = core
    }

    /// Kept while the Agents item shows a run, or its open menu could still act on one.
    var isIdle: Bool {
        chats.isEmpty && scheduler == nil && notifier == nil && ledger.indicator == .hidden
            && !core.agentCoordinator.isMenuBarOpen
    }

    // MARK: - Starting

    /// A launcher run, or a spoken one with its window attached; a HUD announces its start and end.
    @discardableResult
    func start(
        _ task: String, with agent: AgentProfile, attachments: [ChatAttachmentReader.Staged] = []
    ) -> Result<UUID, Refusal> {
        begin(
            task, with: agent, origin: .launcher, title: AgentRun.title(for: task), chatTitle: nil,
            attachments: attachments)
    }

    /// A schedule's run; `manual` is Run Now, which leaves the schedule's own timing alone.
    @discardableResult
    func start(_ schedule: AgentSchedule, manual: Bool) -> Result<UUID, Refusal> {
        guard let agent = store.agent(id: schedule.agentID) else {
            return .failure(.failed(String(localized: "The agent couldn't start.")))
        }
        let now = Date()
        let context = SnippetTemplateEngine.ExpansionContext(
            clipboardHistory: [], selection: "", now: now, calendar: .current, locale: .current,
            timeZone: .current)
        let prompt = SnippetTemplateEngine.expand(text: schedule.prompt, context: context).text
        let result = begin(
            prompt, with: agent, origin: .schedule(schedule.id, manual: manual), title: schedule.name,
            chatTitle: schedule.runTitle(at: now, locale: .current, timeZone: .current), effort: schedule.effort)
        if case .success(let id) = result { scheduleOf[id] = schedule }
        return result
    }

    private func begin(
        _ task: String, with agent: AgentProfile, origin: AgentRun.Origin, title: String,
        chatTitle: String?, attachments: [ChatAttachmentReader.Staged] = [], effort: AgentEffort? = nil
    ) -> Result<UUID, Refusal> {
        guard core.settings.aiEnabled else { return .failure(.aiOff) }
        if origin.isCapped, !AgentSpendPolicy.allowsStart(store.scheduleSpend, on: Self.today()) {
            hold(title, of: agent, origin: origin)
            return .failure(.capped)
        }
        guard ledger.activeCount < Self.maxConcurrent else {
            if origin.announces {
                core.showMessage(String(localized: "Three agents are already running"), tone: .neutral)
            }
            return .failure(.full)
        }
        guard !ledger.isBusy(agent: agent.id) else {
            if origin.announces {
                core.showMessage(
                    String(localized: "\(agent.name) is still working on another task"), tone: .neutral)
            }
            return .failure(.busy(agent.name))
        }
        let ai = core.aiChatCoordinator
        ai.prepareForChat()
        let chat = AIChatState(history: core.chatHistory)
        let id = chat.session.id
        core.agentCoordinator.setAgent(agent, for: chat)
        // Only Always-trusted servers ride an unattended turn: an Ask one raises its own dialog.
        chat.toolScope.excluded = Set(core.mcpCoordinator.servers.filter { $0.trust != .always }.map(\.slug))
        // Staged once the agent is set, so a picture its model cannot see stays behind.
        if !attachments.isEmpty { ai.stage(attachments, into: chat) }
        // Before the send: the turn's prompt, tools, consent and budget all look the run up.
        let effort = effort ?? agent.effortLevel
        ledger.begin(
            AgentRun(
                id: id, agentID: agent.id, agentName: agent.name, symbol: agent.symbol, title: title,
                origin: origin, startedAt: Date(), state: .running, effort: effort))
        guard ai.send(task, in: chat, title: chatTitle) else {
            core.agentCoordinator.setAgent(nil, for: chat)
            let reason = chat.notice ?? String(localized: "The agent couldn't start.")
            ledger.update(id) {
                $0.state = .failed(reason)
                $0.endedAt = Date()
            }
            if origin.announces { core.showMessage(reason, tone: .danger) }
            refreshIndicator()
            return .failure(.failed(reason))
        }
        ai.chats.park(chat)
        chats[id] = chat
        let minutes = effort.budget.minutes
        // The run hands over at its limit by itself; this stops one a long call kept from it.
        watchdogs[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60) + Self.handOverGrace)
            guard !Task.isCancelled else { return }
            self?.timeOut(id, after: minutes)
        }
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated, reason: "An agent is working in the background")
        }
        if origin.announces {
            core.showMessage(
                String(localized: "\(agent.name) is working in the background"), tone: .neutral)
        }
        refreshIndicator()
        watch(chat, id)
        return .success(id)
    }

    /// A due run the cap holds back still gets a row, so the menu bar says why nothing ran.
    private func hold(_ title: String, of agent: AgentProfile, origin: AgentRun.Origin) {
        let now = Date()
        let reason = AgentSpendPolicy.notStarted(cap: store.scheduleSpend.capUSD ?? 0, locale: .current)
        ledger.begin(
            AgentRun(
                id: UUID(), agentID: agent.id, agentName: agent.name, symbol: agent.symbol, title: title,
                origin: origin, startedAt: now, endedAt: now, state: .failed(reason), hasChat: false))
        refreshIndicator()
    }

    private static func today() -> String {
        AgentSpendPolicy.day(of: Date(), calendar: .current)
    }

    /// The scheduler's entry: a busy agent or a full house waits for a run to end.
    private func startScheduled(_ schedule: AgentSchedule) -> AgentScheduler.Start {
        switch start(schedule, manual: false) {
        case .success: .started
        case .failure(.busy), .failure(.full): .busy
        case .failure: .failed
        }
    }

    // MARK: - Consent

    /// True from just before its send until it ends, so the first turn's prompt already knows.
    func isUnattended(_ chatID: UUID) -> Bool {
        ledger.run(chatID)?.isActive == true
    }

    func consentMode(forChat id: UUID) -> AgentConsentMode {
        guard let run = ledger.run(id), run.isActive else { return .foreground }
        let consent = store.agent(id: run.agentID)?.backgroundPolicy.consent ?? .decline
        let idle = Self.anyInput.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }
        return AgentConsentMode.decide(
            isUnattended: true, consent: consent, idleSeconds: idle ?? .infinity)
    }

    /// The native loop's mode for this chat's turn: a run set to decline refuses unasked.
    func runMode(forChat id: UUID) -> AgentRunMode {
        guard let run = ledger.run(id), run.isActive else { return .chat(id) }
        let consent = store.agent(id: run.agentID)?.backgroundPolicy.consent ?? .decline
        return .turn(in: id, isUnattended: true, consent: consent)
    }

    /// An unattended run's effort, which its turn's budget and clock follow; nil for a chat.
    func effort(forChat id: UUID) -> AgentEffort? {
        ledger.run(id).flatMap { $0.isActive ? $0.effort : nil }
    }

    /// Time for the hand-over round between the run's limit and the watchdog's stop.
    static let handOverGrace: Duration = .seconds(120)

    /// Whether this chat's turn is held to the spend cap, so its route is metered.
    func isCapped(_ chatID: UUID) -> Bool {
        ledger.run(chatID).map { $0.isActive && $0.origin.isCapped } ?? false
    }

    /// A capped run's cost so far; once the day's total passes the cap the run is stopped.
    func reportCost(_ cost: Double, forChat id: UUID) {
        guard let run = ledger.run(id), run.isActive, run.origin.isCapped, let chat = chats[id] else { return }
        ledger.update(id) { $0.cost = cost }
        let spend = store.scheduleSpend
        guard cappedAt[id] == nil, let cap = spend.capUSD,
            AgentSpendPolicy.isOver(spend, on: Self.today(), running: ledger.cappedSpend)
        else { return }
        cappedAt[id] = cap
        chat.cancel()
    }

    func noteDeclined(_ chatID: UUID) {
        ledger.update(chatID) { $0.declined += 1 }
        refreshIndicator()
    }

    func waiting(_ chatID: UUID, _ isWaiting: Bool) {
        guard let run = ledger.run(chatID), run.isActive else { return }
        ledger.update(chatID) { $0.state = isWaiting ? .waiting : .running }
        refreshIndicator()
    }

    // MARK: - Indicator

    func open(_ runID: UUID) {
        if ledger.run(runID)?.hasChat == false {
            showSettings()
        } else {
            core.aiChatCoordinator.openChat(id: runID)
            core.aiChatCoordinator.showWindow()
        }
        ledger.update(runID) { $0.isSeen = true }
        notifier?.withdraw(runID)
        refreshIndicator()
        releaseIfIdle()
    }

    func stop(_ runID: UUID) {
        chats[runID]?.cancel()
    }

    // MARK: - Lifecycle

    /// AI on or off, agents or schedules changed: the scheduler and notifier follow.
    func apply() {
        guard core.settings.aiEnabled else {
            stopAll()
            releaseIfIdle()
            return
        }
        let needs = AgentBackgroundNeeds.of(
            aiEnabled: true, agents: store.agents, schedules: store.schedules)
        if needs.notifier, notifier == nil {
            notifier = AgentRunNotifier { [weak self] in self?.open($0) }
        } else if !needs.notifier {
            notifier = nil
        }
        if !needs.scheduler {
            scheduler?.stop()
            scheduler = nil
        } else if let scheduler {
            scheduler.apply(settling: false)
        } else {
            let made = AgentScheduler(store: store) { [weak self] in self?.startScheduled($0) ?? .failed }
            scheduler = made
            made.apply(settling: true)
        }
        releaseIfIdle()
    }

    func stopAll() {
        // AI off or quit cuts capped runs short; what their routes reported still counts today.
        let cutOff = ledger.cappedSpend
        if cutOff > 0 { store.recordScheduledSpend(cutOff, on: Self.today()) }
        for task in watchdogs.values { task.cancel() }
        let running = Array(chats.values)
        watchdogs = [:]
        chats = [:]
        timedOut = [:]
        cappedAt = [:]
        scheduleOf = [:]
        for chat in running { chat.cancel() }
        scheduler?.stop()
        scheduler = nil
        notifier = nil
        ledger = AgentRunLedger()
        refreshIndicator()
        releaseActivity()
    }

    // MARK: - A run's end

    /// Reads `isStreaming` alone, so the reply's flushes never wake it: once at start, once at end.
    private func watch(_ chat: AIChatState, _ id: UUID) {
        guard chats[id] != nil else { return }
        let streaming = withObservationTracking {
            chat.isStreaming
        } onChange: { [weak self, weak chat] in
            Task { @MainActor in
                guard let self, let chat else { return }
                self.watch(chat, id)
            }
        }
        if !streaming { finish(id, chat) }
    }

    private func timeOut(_ id: UUID, after minutes: Int) {
        guard let chat = chats[id] else { return }
        timedOut[id] = minutes
        chat.cancel()
    }

    private func finish(_ id: UUID, _ chat: AIChatState) {
        guard chats.removeValue(forKey: id) != nil else { return }
        watchdogs.removeValue(forKey: id)?.cancel()
        let stoppedAfter = timedOut.removeValue(forKey: id)
        let capped = cappedAt.removeValue(forKey: id)
        let schedule = scheduleOf.removeValue(forKey: id)
        core.aiChatCoordinator.chats.unpark(id: id)
        if chats.isEmpty { releaseActivity() }
        // Off, deleting or quitting replace a chat's session before this runs: read it by id.
        let session = chat.session.id == id ? chat.session : core.chatHistory.session(id: id)
        guard let run = ledger.run(id) else { return settle() }
        let last = session?.messages.last { $0.role == .assistant }
        if let cost = run.spend(final: last?.usage?.costUSD) {
            store.recordScheduledSpend(cost, on: Self.today())
        }
        // Counted first: a chat deleted mid-turn still spent what its route reported.
        guard session != nil else {
            ledger.remove(id)
            return settle()
        }
        let state = AgentRun.endState(
            complete: last?.state == .complete, reply: last?.text, stoppedAfter: stoppedAfter,
            capped: capped.map { AgentSpendPolicy.stopped(cap: $0, locale: .current) })
        let ai = core.aiChatCoordinator
        let watched =
            NSApp.keyWindow?.identifier == AIChatWindowChrome.windowIdentifier
            && ai.chats.window.session.id == id
        ledger.update(id) {
            $0.state = state
            $0.endedAt = Date()
            $0.isSeen = watched
        }
        let agent = store.agent(id: run.agentID)
        if !watched, let ended = ledger.run(id) { deliver(ended, agent: agent) }
        if state == .done, let schedule, let title = schedule.noteTitle, core.settings.notesEnabled,
            let answer = last?.text
        {
            append(answer, of: schedule, toNoteTitled: title, run: id)
        }
        if let agent, agent.runtime != nil,
            !ai.chats.live.contains(where: { core.agentCoordinator.agent(for: $0)?.id == agent.id })
        {
            core.agentCoordinator.acpHost.release(agentID: agent.id)
        }
        settle()
    }

    private func settle() {
        refreshIndicator()
        scheduler?.apply(settling: false)
        releaseIfIdle()
    }

    private func deliver(_ run: AgentRun, agent: AgentProfile?) {
        let reason: String? =
            switch run.state {
            case .failed(let reason): reason
            default: nil
            }
        if run.origin.announces {
            core.showMessage(
                reason == nil
                    ? String(localized: "\(run.agentName) finished")
                    : String(localized: "\(run.agentName) couldn't finish"),
                tone: reason == nil ? .success : .danger)
        }
        if agent?.backgroundPolicy.notifies == true {
            notifier?.post(run, body: reason ?? String(localized: "Finished"))
        }
    }

    private func append(_ answer: String, of schedule: AgentSchedule, toNoteTitled title: String, run: UUID) {
        let block = AgentNoteEntry.block(
            heading: schedule.name, at: Date(), answer: answer, locale: .current, timeZone: .current)
        let notes = core.notesStore
        Task { [weak self] in
            guard let problem = await AgentNoteWriter.append(block, toNoteTitled: title, store: notes)
            else { return }
            self?.ledger.update(run) { $0.problem = problem }
            self?.refreshIndicator()
        }
    }

    // MARK: - Indicator and teardown

    /// The Agents menu-bar item opened: every finished run counts as seen.
    func markFinishedSeen() {
        ledger.markFinishedSeen()
    }

    /// Finished runs leave the menu, and the banners that announced them go too.
    func clearFinished() {
        for run in ledger.runs where !run.isActive { notifier?.withdraw(run.id) }
        ledger.clearFinished()
        refreshIndicator()
    }

    private func refreshIndicator() {
        core.agentCoordinator.refreshMenuBar()
    }

    private func showSettings() {
        core.settingsCoordinator.showSettings(tab: .ai, revealing: .section(.aiAgents))
    }

    private func releaseActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    func releaseIfIdle() {
        if isIdle { onIdle?() }
    }
}
