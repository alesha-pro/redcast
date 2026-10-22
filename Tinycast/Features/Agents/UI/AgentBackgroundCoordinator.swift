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
    }

    private(set) var ledger = AgentRunLedger()

    @ObservationIgnored private let store: AgentStore
    @ObservationIgnored private unowned let core: AppCore
    /// Only while running; the chat itself is parked in AI Chat, which saves it as it goes.
    @ObservationIgnored private var chats: [UUID: AIChatState] = [:]
    @ObservationIgnored private var watchdogs: [UUID: Task<Void, Never>] = [:]
    /// Runs the watchdog stopped, with the limit it stopped them at.
    @ObservationIgnored private var timedOut: [UUID: Int] = [:]
    @ObservationIgnored private var scheduleOf: [UUID: AgentSchedule] = [:]
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var statusItem: AgentRunsStatusItem?
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

    var isIdle: Bool {
        chats.isEmpty && statusItem == nil && scheduler == nil && notifier == nil
    }

    // MARK: - Starting

    /// A launcher run: the task as typed, announced by a HUD at its start and end.
    @discardableResult
    func start(_ task: String, with agent: AgentProfile) -> Result<UUID, Refusal> {
        begin(task, with: agent, origin: .launcher, title: AgentRun.title(for: task), chatTitle: nil)
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
            chatTitle: schedule.runTitle(at: now, locale: .current, timeZone: .current))
        if case .success(let id) = result { scheduleOf[id] = schedule }
        return result
    }

    private func begin(
        _ task: String, with agent: AgentProfile, origin: AgentRun.Origin, title: String,
        chatTitle: String?
    ) -> Result<UUID, Refusal> {
        guard core.settings.aiEnabled else { return .failure(.aiOff) }
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
        // Before the send: the turn's prompt, tools and consent all look the run up.
        ledger.begin(
            AgentRun(
                id: id, agentID: agent.id, agentName: agent.name, symbol: agent.symbol, title: title,
                origin: origin, startedAt: Date(), state: .running))
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
        let minutes = agent.backgroundPolicy.limitMinutes
        watchdogs[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
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
        core.aiChatCoordinator.openChat(id: runID)
        core.aiChatCoordinator.showWindow()
        ledger.update(runID) { $0.isSeen = true }
        notifier?.withdraw(runID)
        refreshIndicator()
        releaseIfIdle()
    }

    func stop(_ runID: UUID) {
        chats[runID]?.cancel()
    }

    // MARK: - Lifecycle

    /// AI on or off, agents or schedules changed: the scheduler, notifier and item follow.
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
        for task in watchdogs.values { task.cancel() }
        let running = Array(chats.values)
        watchdogs = [:]
        chats = [:]
        timedOut = [:]
        scheduleOf = [:]
        for chat in running { chat.cancel() }
        scheduler?.stop()
        scheduler = nil
        notifier = nil
        ledger = AgentRunLedger()
        statusItem?.remove()
        statusItem = nil
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
        let schedule = scheduleOf.removeValue(forKey: id)
        core.aiChatCoordinator.chats.unpark(id: id)
        if chats.isEmpty { releaseActivity() }
        // Off, deleting or quitting replace a chat's session before this runs: read it by id.
        let session = chat.session.id == id ? chat.session : core.chatHistory.session(id: id)
        guard let run = ledger.run(id), let session else {
            ledger.remove(id)
            return settle()
        }
        let last = session.messages.last { $0.role == .assistant }
        let state = AgentRun.endState(
            complete: last?.state == .complete, reply: last?.text, stoppedAfter: stoppedAfter)
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

    private func refreshIndicator() {
        let indicator = ledger.indicator
        guard indicator != .hidden else {
            // An open menu keeps its item; closing it comes back here.
            guard statusItem?.isMenuOpen != true else { return }
            statusItem?.remove()
            statusItem = nil
            return
        }
        let item =
            statusItem
            ?? AgentRunsStatusItem(
                actions: AgentRunsStatusItem.Actions(
                    open: { [weak self] in self?.open($0) },
                    stop: { [weak self] in self?.stop($0) },
                    settings: { [weak self] in self?.showSettings() },
                    viewed: { [weak self] in
                        self?.ledger.markFinishedSeen()
                        self?.refreshIndicator()
                    },
                    closed: { [weak self] in
                        // After the chosen row's action, which AppKit sends once the menu closed.
                        Task { @MainActor in
                            self?.refreshIndicator()
                            self?.releaseIfIdle()
                        }
                    }))
        statusItem = item
        item.show(indicator, runs: ledger.runs)
    }

    private func showSettings() {
        core.settingsCoordinator.showSettings(tab: .ai, revealing: .section(.aiAgents))
    }

    private func releaseActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    private func releaseIfIdle() {
        if isIdle { onIdle?() }
    }
}
