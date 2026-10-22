import AppKit
import os

/// The hub's action surface: the screen, resume and jump, events, and live status in Settings.
@MainActor
final class AgentSessionsCoordinator {
    enum PrimaryAction: Equatable { case jump, resume(AgentTerminal), openChat }

    struct LiveStatusSummary: Equatable {
        var isOn = false
        var states: [AgentHookTarget: AgentHookFileFormat.State] = [:]

        var needsUpdate: Bool { states.values.contains { $0 == .outdated } || (isOn && states.values.contains(.absent)) }
        var isInstalledAnywhere: Bool { isOn || states.values.contains { $0 == .installed || $0 == .outdated } }
    }

    struct LiveStatusPlan: Identifiable {
        let id = UUID()
        let turningOn: Bool
        let token: String
        var changes: [AgentHookFileFormat.Change]
        var snapshots: [AgentHookTarget: AgentHookRepository.Snapshot]
        var problems: [String]
        var notice: String?
        let backups: URL
        /// The agents whose files can take the hooks, which is what an installed record lists.
        let targets: [AgentHookTarget]
    }

    enum LiveStatusResult { case done, changed(LiveStatusPlan), failed(String) }

    private let settings: AppSettings
    private let appIndex: AppIndex
    private let paletteCoordinator: PaletteCoordinator
    private let chatHistory: ChatHistoryStore
    private let agentStore: AgentStore
    private unowned let core: AppCore
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private var builtIndex: AgentSessionIndex?
    private var builtActivity: AgentActivityState?
    /// `ExecutableLocator` spawns a login shell, so its answer, found or not, is kept.
    private var claudeExecutable: URL??
    /// Read from `live-status.json` on the first event; `.some(nil)` means live status is off.
    private var liveToken: String??
    /// Resolved once per open screen; the footer reads it on every render.
    private var installedTerminals: Set<String>?
    private var statusItem: AgentStatusItem?
    private static let log = Logger(subsystem: "com.tinycast", category: "AgentSessions")

    init(
        settings: AppSettings, appIndex: AppIndex, paletteCoordinator: PaletteCoordinator,
        chatHistory: ChatHistoryStore, agentStore: AgentStore, core: AppCore
    ) {
        self.settings = settings
        self.appIndex = appIndex
        self.paletteCoordinator = paletteCoordinator
        self.chatHistory = chatHistory
        self.agentStore = agentStore
        self.core = core
    }

    /// Built on the first screen open, never at launch.
    var index: AgentSessionIndex {
        if let builtIndex { return builtIndex }
        let index = AgentSessionIndex(
            chatHistory: chatHistory, agentStore: agentStore, locations: locations, cacheFolder: Self.cacheFolder,
            claudeExecutable: { [weak self] in await self?.locateClaude() })
        builtIndex = index
        return index
    }

    /// Built on the first event or status read.
    var activity: AgentActivityState {
        if let builtActivity { return builtActivity }
        let activity = AgentActivityState()
        builtActivity = activity
        return activity
    }

    var isActive: Bool { settings.aiEnabled && settings.agentSessionsEnabled }

    /// Read from settings at each use, so a folder moved in Settings counts from the next read on.
    var locations: AgentSessionsLocations {
        AgentSessionsLocations(
            home: home, claudeFolder: settings.agentSessionsClaudeFolder,
            codexFolder: settings.agentSessionsCodexFolder)
    }

    static var cacheFolder: URL {
        AppPaths.caches().appending(path: "agent-sessions", directoryHint: .isDirectory)
    }

    private static var stateFolder: URL {
        AppPaths.applicationSupport().appending(path: "agent-sessions", directoryHint: .isDirectory)
    }

    private static var liveStatusURL: URL {
        stateFolder.appending(path: "live-status.json", directoryHint: .notDirectory)
    }

    /// Command visibility only; no file is read here.
    func applyEnabled() {
        appIndex.setCommandsVisible([.searchAgentSessions, .jumpToAgent], isActive)
        guard !isActive else { return updateStatusItem() }
        builtIndex?.close()
        if core.palette.mode == .agentSessions { core.palette.prepare(mode: .launcher) }
        updateStatusItem()
    }

    /// Off also deletes the caches, which hold titles and prompts.
    func setEnabled(_ enabled: Bool) {
        settings.agentSessionsEnabled = enabled
        guard !enabled else { return }
        let caches = [AgentSource.claude, .gemini].map { AgentSessionIndex.cacheFile($0, in: Self.cacheFolder) }
        Task.detached(priority: .utility) {
            for cache in caches { try? FileManager.default.removeItem(at: cache) }
        }
    }

    func show(query: String? = nil) {
        guard isActive else { return }
        index.open(locations)
        let seed = query.flatMap { $0.isEmpty ? nil : String($0.prefix(AgentDeepLink.queryLimit)) }
        paletteCoordinator.togglePalette(mode: .agentSessions, seeding: seed)
    }

    func screenAppeared() {
        guard isActive else { return }
        index.open(locations)
        if let builtActivity {
            builtActivity.prune(now: Date())
            index.applyReported(builtActivity.items)
        }
    }

    func screenDisappeared() {
        builtIndex?.close()
        installedTerminals = nil
    }

    // MARK: - Rows

    func primaryAction(for session: AgentSession) -> PrimaryAction {
        if session.source == .tinycast { return .openChat }
        return focusTarget(for: session) != nil ? .jump : .resume(terminal(for: session))
    }

    func primaryTitle(for session: AgentSession) -> String {
        switch primaryAction(for: session) {
        case .jump: String(localized: "Jump to Session")
        case .resume(let terminal): String(localized: "Resume in \(terminal.displayName)")
        case .openChat: String(localized: "Open Chat")
        }
    }

    func terminal(for session: AgentSession) -> AgentTerminal {
        let installed = installedTerminals ?? AgentTerminalRunner.installed()
        installedTerminals = installed
        let host =
            builtIndex?.live[session.id]?.hostBundleID
            ?? builtActivity?.items.first { $0.id == session.id }?.hostBundleID
        return AgentTerminalPolicy.choose(
            preferred: settings.agentSessionsTerminal, lastHostBundleID: host, installed: installed)
    }

    func canOpenInApp(_ session: AgentSession) -> Bool {
        switch session.source {
        case .tinycast: true
        case .claude: session.host == .claudeApp
        case .codex: NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentActivityPolicy.codexApp) != nil
        case .gemini, .openCode: false
        }
    }

    /// One `stat`; a row asks only while it is on screen.
    static func folderExists(_ directory: String?) -> Bool {
        guard let directory else { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Actions

    /// ↵: a live session comes forward where it runs; any other one resumes in its folder.
    func activate(_ session: AgentSession) {
        switch primaryAction(for: session) {
        case .openChat: openChat(session, inQuickAI: false)
        case .jump:
            guard let target = focusTarget(for: session) else { return }
            paletteCoordinator.hidePalette(restoreFocus: false)
            focus(host: target.bundleID, tty: target.tty, status: target.status)
        case .resume: resume(session, action: .resume)
        }
    }

    func resume(_ session: AgentSession, action: AgentResumeAction) {
        guard let command = resumeCommand(session, action: action) else {
            core.showMessage(String(localized: "This session can't be resumed"), tone: .danger)
            return
        }
        guard Self.folderExists(session.directory) else {
            _ = Paster.copyPlainText(command)
            core.showMessage(
                String(localized: "This folder no longer exists. The resume command is copied."), tone: .neutral)
            return
        }
        let terminal = terminal(for: session)
        paletteCoordinator.hidePalette(restoreFocus: false)
        run(action == .openFolder ? nil : command, in: session.directory, terminal: terminal, copying: command)
    }

    func copyResumeCommand(_ session: AgentSession) {
        guard let command = resumeCommand(session, action: .resume) else {
            core.showMessage(String(localized: "This session can't be resumed"), tone: .danger)
            return
        }
        _ = Paster.copyPlainText(command)
        core.showMessage(String(localized: "Resume command copied"))
    }

    func resumeCommand(_ session: AgentSession, action: AgentResumeAction) -> String? {
        AgentResumeCommand.command(
            for: session, action: action, environment: locations.environment(for: session.source))
    }

    func openInApp(_ session: AgentSession) {
        switch session.source {
        case .tinycast:
            openChat(session, inQuickAI: false)
        case .claude:
            guard session.host == .claudeApp else { return }
            paletteCoordinator.hidePalette(restoreFocus: false)
            openClaudeApp(transcriptID: session.sessionID)
        case .codex:
            guard AgentResumeCommand.isSafeID(session.sessionID),
                let url = URL(string: "codex://threads/" + session.sessionID)
            else { return }
            paletteCoordinator.hidePalette(restoreFocus: false)
            NSWorkspace.shared.open(url)
        case .gemini, .openCode:
            break
        }
    }

    func openChat(_ session: AgentSession, inQuickAI: Bool) {
        guard session.source == .tinycast, let id = UUID(uuidString: session.sessionID) else { return }
        if inQuickAI {
            core.quickAICoordinator.openChat(id: id)
        } else {
            core.quickAICoordinator.continueInChat(id: id)
        }
    }

    func showFolder(_ session: AgentSession) {
        guard let directory = session.directory else { return }
        guard Self.folderExists(session.directory) else {
            core.showMessage(String(localized: "Folder no longer exists"), tone: .danger)
            return
        }
        paletteCoordinator.hidePalette(restoreFocus: false)
        NSWorkspace.shared.open(URL(filePath: directory, directoryHint: .isDirectory))
    }

    func copyFolderPath(_ session: AgentSession) {
        guard let directory = session.directory else { return }
        _ = Paster.copyPlainText(directory)
        core.showMessage(String(localized: "Copied path"))
    }

    func copySessionID(_ session: AgentSession) {
        guard session.source != .tinycast else { return }
        _ = Paster.copyPlainText(session.sessionID)
        core.showMessage(String(localized: "Copied session ID"))
    }

    // MARK: - Jump

    /// The newest waiting agent, else the newest unseen finished one; without hooks, the probe.
    func jumpToAgent() {
        guard isActive else { return }
        if let builtActivity {
            builtActivity.prune(now: Date())
            if let target = AgentActivityPolicy.jumpTarget(builtActivity.items) { return jump(to: target) }
        }
        let locations = locations
        Task {
            guard let executable = await locateClaude() else {
                return core.showMessage(String(localized: "No agent is waiting"), tone: .neutral)
            }
            let entries = await AgentProcessHost.resolving(
                await ClaudeLiveSessionsProbe.run(
                    executable: executable, home: locations.home, environment: locations.environment(for: .claude)))
            let waiting = entries.filter { entry in
                guard case .waiting = entry.status else { return false }
                return !isTinycastOwned(sessionID: entry.sessionID, hostBundleID: entry.hostBundleID)
            }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            guard let entry = waiting.first(where: { $0.hostBundleID != nil }), let host = entry.hostBundleID else {
                return core.showMessage(String(localized: "No agent is waiting"), tone: .neutral)
            }
            paletteCoordinator.hidePalette(restoreFocus: false)
            focus(host: host, tty: entry.tty, status: entry.status)
        }
    }

    func jump(to activity: AgentActivity) {
        builtActivity?.markSeen(activity.id)
        updateStatusItem()
        if let host = activity.hostBundleID {
            paletteCoordinator.hidePalette(restoreFocus: false)
            return focus(host: host, tty: activity.tty, status: activity.status)
        }
        let session = AgentSession(
            source: activity.agent, sessionID: activity.sessionID, title: activity.title ?? "",
            titleOrigin: .named, directory: activity.directory, createdAt: activity.updatedAt,
            updatedAt: activity.updatedAt, host: activity.host)
        // Without a host it may still be open somewhere unseen, so only an ended one is reopened.
        guard activity.status == .ended else { return copyResumeCommand(session) }
        resume(session, action: .resume)
    }

    // MARK: - Deep links and events

    /// True for every `tinycast://agent-sessions/…` URL, handled or dropped.
    func handleOpenURL(_ url: URL) -> Bool {
        guard AgentDeepLink.claims(url) else { return false }
        guard url.path() == "/event" else {
            switch AgentDeepLink.parse(url, token: nil) {
            case .open(let query): show(query: query)
            case .jump: jumpToAgent()
            case .event, nil: Self.log.debug("Dropped an agent-sessions link")
            }
            return true
        }
        guard isActive else { return true }
        // Stamped on arrival, so two events resolving out of order still apply in order.
        let received = Date()
        Task {
            let token = await loadToken()
            guard case .event(let event)? = AgentDeepLink.parse(url, token: token) else {
                return Self.log.debug("Dropped an agent event")
            }
            await handle(event, now: received)
        }
        return true
    }

    private func handle(_ event: AgentEvent, now: Date) async {
        let locations = locations
        async let host = AgentProcessHost.hosting(event.pid)
        var resolved = await AgentSessionsScanner.resolve(
            event, claudeRoot: locations.claudeProjects, codexState: locations.codexState, now: now)
        (resolved.hostBundleID, resolved.tty) = await host
        guard isActive else { return }
        if isTinycastOwned(sessionID: event.sessionID, hostBundleID: resolved.hostBundleID) { resolved.host = .tinycast }
        if let (previous, current) = activity.apply(event, resolved: resolved, now: now) {
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if let announcement = AgentActivityPolicy.announcement(
                for: current, previous: previous, frontmostBundleID: frontmost,
                lastAnnounced: activity.lastAnnounced(current.id, kind: event.event), now: now)
            {
                activity.recordAnnouncement(current.id, kind: announcement.kind, at: now)
                core.showMessage(
                    Self.message(for: current, kind: announcement.kind), tone: announcement.tone.dialogTone)
            }
        }
        builtIndex?.applyReported(activity.items)
        updateStatusItem()
    }

    private func isTinycastOwned(sessionID: String, hostBundleID: String?) -> Bool {
        AgentActivityPolicy.isTinycastOwned(
            sessionID: sessionID, hostBundleID: hostBundleID, acpSessions: Set(agentStore.acpSessions.values),
            appBundleID: Bundle.main.bundleIdentifier)
    }

    /// Built from Tinycast's own lookup of the session; nothing from the URL is ever shown.
    private static func message(for activity: AgentActivity, kind: AgentHookEvent) -> String {
        let agent = activity.agent.productName
        let folder = activity.directory.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        switch (kind, folder) {
        case (.waiting, let folder?): return String(localized: "\(agent) needs you in \(folder)")
        case (.waiting, nil): return String(localized: "\(agent) needs you")
        case (.failed, let folder?): return String(localized: "\(agent) stopped with an error in \(folder)")
        case (.failed, nil): return String(localized: "\(agent) stopped with an error")
        case (_, let folder?): return String(localized: "\(agent) finished in \(folder)")
        case (_, nil): return String(localized: "\(agent) finished")
        }
    }

    private func loadToken() async -> String? {
        if let liveToken { return liveToken }
        let token = await AgentHookRepository.loadLiveStatus(Self.liveStatusURL)?.token
        liveToken = .some(token)
        return token
    }

    // MARK: - Status item

    func setStatusItemEnabled(_ enabled: Bool) {
        settings.agentStatusMenuBar = enabled
        updateStatusItem()
    }

    /// Present only while an agent works, waits, or finished unseen; removed when the list empties.
    private func updateStatusItem() {
        builtActivity?.prune(now: Date())
        let items = builtActivity?.items ?? []
        guard isActive, settings.agentStatusMenuBar, items.contains(where: \.needsAttention) else {
            statusItem?.remove()
            statusItem = nil
            return
        }
        if statusItem == nil {
            statusItem = AgentStatusItem(
                rows: { [weak self] in
                    self?.builtActivity?.prune(now: Date())
                    return self?.builtActivity?.items.filter(\.needsAttention) ?? []
                },
                onOpen: { [weak self] in self?.builtActivity?.markFinishedSeen() },
                onClose: { [weak self] in self?.updateStatusItem() },
                onSelect: { [weak self] activity in self?.jump(to: activity) },
                onSearch: { [weak self] in self?.show() },
                onClear: { [weak self] in
                    self?.builtActivity?.clearFinished()
                    self?.updateStatusItem()
                })
        }
        statusItem?.update(waiting: items.filter { if case .waiting = $0.status { true } else { false } }.count)
    }

    // MARK: - Live status

    func liveStatusSummary() async -> LiveStatusSummary {
        let record = await AgentHookRepository.loadLiveStatus(Self.liveStatusURL)
        liveToken = .some(record?.token)
        var summary = LiveStatusSummary(isOn: record != nil)
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let locations = locations
        for target in AgentHookTarget.allCases {
            let snapshot = await AgentHookRepository.snapshot(target, locations: locations)
            guard snapshot.isAgentPresent else { continue }
            summary.states[target] =
                snapshot.isReadable
                ? AgentHookFileFormat.state(of: snapshot.text, target: target, bundleID: bundleID, token: record?.token)
                : .unreadable("not UTF-8 text")
        }
        return summary
    }

    func prepareLiveStatus(on: Bool) async -> LiveStatusPlan {
        let record = await AgentHookRepository.loadLiveStatus(Self.liveStatusURL)
        let token = record?.token ?? AgentHookRepository.newToken()
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        var changes: [AgentHookFileFormat.Change] = []
        var snapshots: [AgentHookTarget: AgentHookRepository.Snapshot] = [:]
        var problems: [String] = []
        var targets: [AgentHookTarget] = []
        let locations = locations
        for target in AgentHookTarget.allCases {
            let snapshot = await AgentHookRepository.snapshot(target, locations: locations)
            guard snapshot.isAgentPresent else { continue }
            targets.append(target)
            snapshots[target] = snapshot
            let file = (snapshot.url.path as NSString).abbreviatingWithTildeInPath
            guard snapshot.isReadable else {
                problems.append(String(localized: "Tinycast could not read \(file). Fix the file, then try again."))
                targets.removeLast()
                continue
            }
            do throws(AgentHookFileFormat.Failure) {
                if on {
                    let change = try AgentHookFileFormat.install(
                        into: snapshot.text, target: target, bundleID: bundleID, token: token)
                    if !change.isEmpty { changes.append(change) }
                } else if let text = snapshot.text,
                    let change = try AgentHookFileFormat.remove(from: text, target: target, bundleID: bundleID)
                {
                    changes.append(change)
                }
            } catch .allHooksDisabled {
                targets.removeLast()
                problems.append(
                    String(
                        localized: """
                            Claude Code has every hook turned off (disableAllHooks), so live status can't work.
                            """))
            } catch {
                targets.removeLast()
                problems.append(String(localized: "Tinycast could not read \(file). Fix the file, then try again."))
            }
        }
        return LiveStatusPlan(
            turningOn: on, token: token, changes: changes, snapshots: snapshots, problems: problems,
            backups: Self.stateFolder.appending(path: "hook-backups", directoryHint: .isDirectory), targets: targets)
    }

    /// A file that moved on since the diff sends the panel back to review.
    func apply(_ plan: LiveStatusPlan) async -> LiveStatusResult {
        do throws(AgentHookRepository.Failure) {
            try await AgentHookRepository.apply(plan.changes, expected: plan.snapshots, backups: plan.backups, now: Date())
        } catch .changed(let target) {
            return await changed(plan, target)
        } catch {
            guard case .writeFailed(let message) = error else { return .failed("") }
            return .failed(message)
        }
        if plan.turningOn {
            let record = LiveStatusRecord(token: plan.token, targets: plan.targets, installedAt: Date())
            await AgentHookRepository.saveLiveStatus(record, to: Self.liveStatusURL)
            liveToken = .some(plan.token)
            core.showMessage(String(localized: "Live status is on"))
        } else {
            await AgentHookRepository.saveLiveStatus(nil, to: Self.liveStatusURL)
            liveToken = .some(nil)
            builtActivity?.removeAll()
            builtIndex?.applyReported([])
            updateStatusItem()
            core.showMessage(String(localized: "Live status is off"))
        }
        return .done
    }

    private func changed(_ plan: LiveStatusPlan, _ target: AgentHookTarget) async -> LiveStatusResult {
        var fresh = await prepareLiveStatus(on: plan.turningOn)
        let file = (locations.hookFile(target).path as NSString).abbreviatingWithTildeInPath
        fresh.notice = String(localized: "\(file) changed while you were reviewing it.")
        return .changed(fresh)
    }

    // MARK: - Private

    private func focusTarget(for session: AgentSession) -> (bundleID: String, tty: String?, status: AgentLiveStatus)? {
        guard session.source != .tinycast else { return nil }
        if let entry = builtIndex?.live[session.id], entry.status.isLive, let host = entry.hostBundleID {
            return (host, entry.tty, entry.status)
        }
        if let activity = builtActivity?.items.first(where: { $0.id == session.id }), activity.status.isLive,
            let host = activity.hostBundleID
        {
            return (host, activity.tty, activity.status)
        }
        return nil
    }

    private func focus(host: String, tty: String?, status: AgentLiveStatus) {
        let app = AgentActivityPolicy.appBundleID(host)
        if app == AgentActivityPolicy.claudeApp, case .waiting = status,
            let url = URL(string: "claude://code/needs-input")
        {
            NSWorkspace.shared.open(url)
            return
        }
        Task { _ = await AgentTerminalRunner.focus(bundleID: app, tty: tty) }
    }

    private func activateApp(_ bundleID: String) {
        Task { _ = await AgentTerminalRunner.focus(bundleID: bundleID, tty: nil) }
    }

    /// The app's own record names the session to continue; without one, Claude only comes forward.
    private func openClaudeApp(transcriptID: String) {
        let records = locations.claudeAppSessions
        Task {
            let desktopID = await AgentSessionsScanner.claudeAppSession(transcriptID: transcriptID, root: records)
            guard let url = desktopID.flatMap(ClaudeAppRoute.continueURL(desktopID:)),
                let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentActivityPolicy.claudeApp)
            else { return activateApp(AgentActivityPolicy.claudeApp) }
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init())
        }
    }

    private func run(_ command: String?, in directory: String?, terminal: AgentTerminal, copying copied: String) {
        Task {
            do throws(AgentTerminalRunner.Failure) {
                let outcome = try await AgentTerminalRunner.run(command, in: directory, terminal: terminal)
                guard outcome == .pasteToResume, let command else { return }
                _ = Paster.copyPlainText(command)
                core.showMessage(
                    String(localized: "Paste the command in \(terminal.displayName) to resume"), tone: .neutral)
            } catch .automationDenied(let denied) {
                _ = Paster.copyPlainText(copied)
                core.showMessage(
                    String(
                        localized: "Allow Tinycast to control \(denied.displayName) in Automation settings, then try again."),
                    tone: .danger)
            } catch {
                Self.log.error("Resume failed: \(String(describing: error), privacy: .public)")
                _ = Paster.copyPlainText(copied)
                core.showMessage(String(localized: "Resume command copied"), tone: .neutral)
            }
        }
    }

    private func locateClaude() async -> URL? {
        if let claudeExecutable { return claudeExecutable }
        let found = await ExecutableLocator.locate("claude")
        claudeExecutable = .some(found)
        return found
    }
}

private extension AgentActivityPolicy.Announcement.Tone {
    var dialogTone: DialogTone {
        switch self {
        case .success: .success
        case .neutral: .neutral
        case .danger: .danger
        }
    }
}
