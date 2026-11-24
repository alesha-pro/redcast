import AppKit
import AVFoundation
import Observation

/// Owns Live Voice sessions, consent, screen permission, tools, capsule, pointer and chat saving.
@MainActor
@Observable
final class LiveVoiceCoordinator {
    enum Phase: Equatable {
        case idle
        case starting
        case active
    }

    private static let cardActionID = UUID(uuidString: "B64E2E2B-6C5F-4A93-9311-62B249D5E64A") ?? UUID()

    private(set) var phase: Phase = .idle

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let liveVoice: LiveVoiceSettings
    @ObservationIgnored private let aiSettings: AISettingsStore
    @ObservationIgnored private let appIndex: AppIndex
    @ObservationIgnored private let injector: TextInjector
    @ObservationIgnored private let requestMicrophone: @MainActor () async -> Bool
    @ObservationIgnored private unowned let core: AppCore

    @ObservationIgnored private var session: LiveVoiceSession?
    @ObservationIgnored private var capsule: LiveVoiceCapsuleController?
    @ObservationIgnored private var pointer: LiveVoicePointerController?
    @ObservationIgnored private var cardPanel: QuickActionPanelController?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var consentTask: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()

    @ObservationIgnored private var activeChatID: UUID?
    @ObservationIgnored private var activeChatCreatedAt = Date()
    @ObservationIgnored private var activeChatBound = false
    @ObservationIgnored private var activeAgent: AgentProfile?
    @ObservationIgnored private var activeRoute: AIModelSelection?
    @ObservationIgnored private var activeProvider: LiveVoiceProvider?
    @ObservationIgnored private var activeTargetApp: NSRunningApplication?
    @ObservationIgnored private var activeScreenShared = false
    @ObservationIgnored private var activeInitialScreenPending = false
    @ObservationIgnored private var toolOrigins: [String: String] = [:]
    @ObservationIgnored private var transcript = LiveVoiceTranscript()

    init(
        settings: AppSettings, liveVoice: LiveVoiceSettings, aiSettings: AISettingsStore,
        appIndex: AppIndex, injector: TextInjector, core: AppCore,
        requestMicrophone: @escaping @MainActor () async -> Bool = {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
    ) {
        self.settings = settings
        self.liveVoice = liveVoice
        self.aiSettings = aiSettings
        self.appIndex = appIndex
        self.injector = injector
        self.requestMicrophone = requestMicrophone
        self.core = core
    }

    var isActive: Bool { settings.aiEnabled && liveVoice.enabled }
    var isBusy: Bool { phase != .idle }

    /// The consented Live Voice connection and model; never substitutes another connection.
    var route: AIModelSelection? {
        LiveVoiceRoutePolicy.route(
            liveVoice.model, connections: aiSettings.connections, isEnabled: isRouteEnabled)
    }

    var proposal: AIModelSelection? {
        LiveVoiceRoutePolicy.proposal(
            liveVoice.model, connections: aiSettings.connections, isEnabled: isRouteEnabled)
    }

    /// The consented screen pointer vision model; nil turns pointing off.
    var locatorRoute: AIModelSelection? {
        LiveVoiceRoutePolicy.locatorRoute(
            liveVoice.locatorModel, connections: aiSettings.connections, isEnabled: isRouteEnabled)
    }

    var locatorProposal: AIModelSelection? {
        LiveVoiceRoutePolicy.locatorProposal(
            liveVoice.locatorModel, connections: aiSettings.connections, isEnabled: isRouteEnabled)
    }

    var agent: AgentProfile? {
        guard let id = liveVoice.agent else { return nil }
        return core.agentCoordinator.agents.first { $0.id == id }
    }

    var availableAgents: [AgentProfile] { core.agentCoordinator.agents }

    var activeProviderKind: LiveVoiceProvider? {
        guard case .api(let id, _, _) = route, let connection = aiSettings.connection(id: id) else {
            return nil
        }
        return LiveVoiceRoutePolicy.provider(for: connection)
    }

    func applyEnabled() {
        appIndex.setCommandsVisible([.liveVoice], isActive)
        if !isActive { stop() }
    }

    /// Enabling asks explicit consent naming connection and model, then microphone access.
    func setEnabled(_ enabled: Bool) {
        guard enabled != liveVoice.enabled else { return }
        guard enabled else {
            consentTask?.cancel()
            liveVoice.enabled = false
            stop()
            return
        }
        guard let proposal else { return }
        let proposedLocator = liveVoice.locatorModel ?? locatorProposal
        NSApp.activate()
        askEnableConsent(live: proposal, locator: proposedLocator) { [weak self] in
            guard let self else { return }
            let granted = await requestMicrophone()
            guard !Task.isCancelled else { return }
            guard granted else {
                core.showMessage(
                    String(localized: "Allow Redcast to use the microphone in System Settings"),
                    tone: .danger)
                return
            }
            liveVoice.model = proposal
            if liveVoice.locatorModel == nil { liveVoice.locatorModel = proposedLocator }
            liveVoice.enabled = true
        }
    }

    func choose(_ selection: AIModelSelection) {
        let providerChanged = provider(of: selection) != provider(of: route)
        guard liveVoice.enabled, selection.source != route?.source else {
            liveVoice.model = selection
            if providerChanged { liveVoice.voice = nil }
            return
        }
        askSwitchConsent(to: selection, forPointer: false) { [weak self] in
            guard let self else { return }
            liveVoice.model = selection
            if providerChanged { liveVoice.voice = nil }
        }
    }

    func chooseLocator(_ selection: AIModelSelection?) {
        guard let selection else {
            liveVoice.locatorModel = nil
            return
        }
        guard liveVoice.enabled, selection.source != locatorRoute?.source else {
            liveVoice.locatorModel = selection
            return
        }
        askSwitchConsent(to: selection, forPointer: true) { [weak self] in
            self?.liveVoice.locatorModel = selection
        }
    }

    func toggle() {
        guard isActive else { return }
        if phase != .idle {
            stop()
        } else {
            start()
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        token = UUID()
        let active = session
        session = nil
        if let active {
            active.stop()
        } else {
            finishSessionCleanup()
        }
    }

    func prepareForTermination() {
        consentTask?.cancel()
        stop()
    }

    // MARK: - Starting a session

    private func start() {
        if settings.dictationEnabled, core.dictationCoordinator.isBusy {
            core.showMessage(
                String(localized: "Finish dictation before starting Live Voice."), tone: .neutral)
            return
        }
        if core.voiceAskCoordinator.isBusy {
            core.showMessage(
                String(localized: "Finish Ask by Voice before starting Live Voice."), tone: .neutral)
            return
        }
        guard let route else {
            core.showMessage(
                String(localized: "Choose a Live Voice connection in Settings \u{2192} AI."),
                tone: .danger)
            return
        }
        let provider: LiveVoiceProvider
        let wire: any LiveVoiceWire
        do {
            let built = try LiveVoiceRoute.wire(
                for: route, effort: liveVoice.effort, settings: aiSettings)
            provider = built.provider
            wire = built.wire
        } catch {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        var locator: LiveVoicePointLocator?
        var locatorSelection: AIModelSelection?
        if let selectedLocator = locatorRoute {
            do {
                locator = try LiveVoiceRoute.locator(for: selectedLocator, settings: aiSettings)
                locatorSelection = selectedLocator
            } catch {
                core.showMessage(
                    String(localized: "Screen pointer unavailable: \(error.localizedDescription)"),
                    tone: .neutral)
            }
        }
        let targetApp = externalTargetApp()
        if core.paletteCoordinator.isVisible {
            core.paletteCoordinator.hidePalette(restoreFocus: true)
        }
        cardPanel?.dismiss()
        pointer?.dismiss()
        token = UUID()
        let current = token
        phase = .starting
        let selectedAgent = agent
        let screenMode = liveVoice.screenMode
        let audioMode = liveVoice.audioMode
        let voiceChoice = liveVoice.voice
        let languageSetting = liveVoice.language

        startTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.token == current { self.startTask = nil } }
            let screenConsent = await resolveScreenConsent(
                mode: screenMode, live: route, locator: locatorSelection)
            guard !Task.isCancelled, token == current else { return }
            guard let shareScreen = screenConsent else {
                phase = .idle
                return
            }
            let (persona, memory) = await loadAgentPrompt(selectedAgent)
            guard !Task.isCancelled, token == current else { return }
            if core.mcpCoordinator.isActive { await core.mcpCoordinator.warmUpAndWait() }
            guard !Task.isCancelled, token == current else { return }
            launchSession(
                token: current, provider: provider, wire: wire, route: route,
                locator: shareScreen ? locator : nil, screenMode: screenMode,
                screenShared: shareScreen, audioMode: audioMode, voiceChoice: voiceChoice,
                languageSetting: languageSetting, agent: selectedAgent, persona: persona,
                memory: memory, targetApp: targetApp)
        }
    }

    private func launchSession(
        token current: UUID, provider: LiveVoiceProvider, wire: any LiveVoiceWire,
        route: AIModelSelection, locator: LiveVoicePointLocator?, screenMode: LiveVoiceScreenMode,
        screenShared: Bool, audioMode: LiveVoiceAudioMode, voiceChoice: String?,
        languageSetting: String?, agent: AgentProfile?, persona: String, memory: String,
        targetApp: NSRunningApplication?
    ) {
        let chatID = UUID()
        activeChatID = chatID
        activeChatCreatedAt = Date()
        activeChatBound = false
        activeAgent = agent
        activeRoute = route
        activeProvider = provider
        activeTargetApp = targetApp
        activeScreenShared = screenShared
        activeInitialScreenPending =
            screenShared && screenMode == .everyTurn && !provider.reportsSpeechStart
        transcript = LiveVoiceTranscript()
        toolOrigins = [:]

        var sources: [any LiveVoiceToolSource] = []
        var screenTools: LiveVoiceScreenTools?
        let sendsEachTurn = screenShared && screenMode == .everyTurn && provider.reportsSpeechStart
        if screenShared {
            let offersLook =
                screenMode == .onRequest || (screenMode == .everyTurn && !provider.reportsSpeechStart)
            let locate: LiveVoiceScreenTools.Locate?
            if let locator {
                locate = { jpeg, target in await locator.locate(jpeg, target) }
            } else {
                locate = nil
            }
            let pointerController = pointerInstance()
            let tools = LiveVoiceScreenTools(
                offersLook: offersLook,
                capture: { await LiveVoiceScreenshotter.capture() },
                locate: locate,
                point: { [weak pointerController] at, label in
                    pointerController?.show(at: at, label: label)
                })
            screenTools = tools
            sources.append(tools)
            for tool in tools.tools { toolOrigins[tool.name] = tool.origin }
        }

        let cardTools = LiveVoiceCardTools { [weak self] title, text in
            self?.presentCard(title: title, text: text)
        }
        sources.append(cardTools)
        for tool in cardTools.tools { toolOrigins[tool.name] = tool.origin }

        if let agent {
            let taskTools = LiveVoiceTaskTools { [weak self] task in
                self?.launchBackgroundTask(task, with: agent)
                    ?? .refused("Live Voice session ended.")
            }
            sources.append(taskTools)
            for tool in taskTools.tools { toolOrigins[tool.name] = tool.origin }
        }

        let mcpTools = core.mcpCoordinator.tools(scopedTo: nil)
        if !mcpTools.isEmpty {
            let mcpSource = LiveVoiceToolList(tools: mcpTools) { [weak self] call in
                guard let self else { return .failure(call.id, "Live Voice session ended.") }
                return await self.core.mcpCoordinator.invoke(call, in: chatID)
            }
            sources.append(mcpSource)
            for tool in mcpTools { toolOrigins[tool.name] = tool.origin }
        }

        let toolbox = LiveVoiceToolbox(sources: sources)
        let promptScreen: LiveVoicePrompt.Screen =
            screenShared && screenMode == .everyTurn ? .everyTurn : .onRequest
        let language = LiveVoiceRoutePolicy.resolvedLanguage(
            setting: languageSetting, preferredLanguages: SystemLanguages.preferred)
        let instructions = LiveVoicePrompt.instructions(
            name: agent?.name ?? "Redcast", persona: persona, memory: memory,
            language: language.englishName, screen: promptScreen, tools: toolbox.tools)
        let voice = voiceChoice.flatMap { provider.voices.contains($0) ? $0 : nil } ?? provider.defaultVoice
        let setup = LiveVoiceSetup(
            instructions: instructions, tools: toolbox.tools, voice: voice, language: language.code)
        let echo: LiveVoiceAudio.Echo =
            switch audioMode {
            case .automatic: .cancelled
            case .headphones: .open
            case .mutedWhileSpeaking: .muted
            }

        let audio = LiveVoiceAudio()
        let capsule = capsuleInstance()
        audio.onLevels = { [weak capsule] levels in
            capsule?.state.levels = levels
        }
        let session = LiveVoiceSession(
            wire: wire, setup: setup, toolbox: toolbox, screen: screenTools,
            sendsScreenEachTurn: sendsEachTurn, audio: audio, echo: echo,
            microphoneUID: settings.dictationMicrophone,
            maxConnectionLifetime: provider.maxConnectionLifetime
        ) { [weak self] update in
            self?.handle(update, token: current)
        }
        self.session = session
        phase = .active
        capsule.show(agentName: agent?.name, screenShared: screenShared)
        session.start()
    }

    // MARK: - Session updates

    private func handle(_ update: LiveVoiceSession.Update, token current: UUID) {
        guard token == current else { return }
        switch update {
        case .ready:
            if activeInitialScreenPending {
                activeInitialScreenPending = false
                let active = session
                Task { await active?.lookNow() }
            }
            capsule?.state.activeTool = nil
            if capsule?.state.isMuted == true {
                capsule?.state.phase = .muted
            } else {
                capsule?.state.phase = .listening
            }
        case .listening:
            capsule?.state.activeTool = nil
            capsule?.state.phase = capsule?.state.isMuted == true ? .muted : .listening
        case .userSpeaking:
            capsule?.state.activeTool = nil
            capsule?.state.phase = .userSpeaking
        case .thinking:
            capsule?.state.phase = .thinking
        case .speaking:
            capsule?.state.activeTool = nil
            capsule?.state.phase = .speaking
        case .reconnecting:
            capsule?.state.activeTool = nil
            capsule?.state.phase = .reconnecting
        case .heard(let text):
            transcript.noteUserText(text)
        case .said(let text):
            transcript.noteAssistantText(text)
        case .calling(let call):
            transcript.noteToolCall(call, origin: toolOrigins[call.name] ?? "Live Voice")
            capsule?.state.activeTool = toolStatusLabel(for: call.name)
        case .tool(let call, let result):
            transcript.noteToolResult(call, result: result)
        case .replyEnded(let usage):
            transcript.finishReply()
            persistTranscript()
            if let usage, let route = activeRoute { recordUsage(usage, route: route) }
        case .latency:
            break
        case .failed(let message):
            core.showMessage(message, tone: .danger)
        case .closed:
            finishSessionCleanup()
        }
    }

    private func finishSessionCleanup() {
        transcript.finishAll()
        persistTranscript()
        session = nil
        capsule?.close()
        pointer?.dismiss()
        phase = .idle
        activeChatID = nil
        activeChatBound = false
        activeAgent = nil
        activeRoute = nil
        activeProvider = nil
        activeScreenShared = false
        activeInitialScreenPending = false
        toolOrigins = [:]
    }

    // MARK: - Tools, chat history and usage

    private func launchBackgroundTask(
        _ task: String, with agent: AgentProfile
    ) -> LiveVoiceTaskTools.Launch {
        switch core.agentCoordinator.background.start(task, with: agent) {
        case .success(let runID):
            return .started { [weak self] in
                guard let self else { return "The Live Voice session ended." }
                let completion = await self.core.agentCoordinator.background.awaitCompletion(of: runID)
                let reply = LiveVoiceRoutePolicy.boundedText(completion.reply, maxBytes: 4_000)
                switch completion.state {
                case .done:
                    return reply.isEmpty ? "Finished without a written summary." : reply
                case .failed(let reason):
                    return reply.isEmpty ? "Failed: \(reason)" : "Failed (\(reason)): \(reply)"
                case .running, .waiting:
                    return reply.isEmpty ? "Stopped." : reply
                }
            }
        case .failure(.busy(let name)):
            return .refused("\(name) is already working on another task.")
        case .failure(.full):
            return .refused("Three background agent tasks are already running.")
        case .failure(.aiOff):
            return .refused("AI is turned off.")
        case .failure(.capped):
            return .refused("The daily spend cap has been reached.")
        case .failure(.failed(let reason)):
            return .refused(reason)
        }
    }

    private func presentCard(title: String, text: String) {
        let action = CustomQuickAction(
            id: Self.cardActionID,
            name: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "Live Voice") : title,
            iconSymbol: CommandID.liveVoice.sfSymbol, instructions: "", previewsResult: true,
            createdAt: .distantPast)
        let state = QuickActionPanelState(
            action: .custom(action), original: "", targetLanguage: Locale.current.language)
        state.finish(text)
        let panel = cardPanel ?? QuickActionPanelController()
        cardPanel = panel
        let chatID = activeChatID
        panel.present(
            state, metrics: settings.interfaceSize.metrics, languages: [], onRetranslate: { _ in },
            onReplace: { [weak self] content in self?.pasteCard(content) },
            onContinueInChat: settings.aiEnabled
                ? { [weak self] content in self?.openCardInChat(chatID: chatID, title: title, text: content) }
                : nil)
    }

    private func pasteCard(_ text: String) {
        guard let target = externalTargetApp() ?? activeTargetApp else {
            Paster.copyPlainText(text)
            core.showMessage(String(localized: "Copied to clipboard"))
            return
        }
        injector.deliver(
            InjectedText(text), target: .external(target), expectedKeyword: nil, keywordLength: 0,
            automaticGeneration: nil, isValid: { true },
            onFailed: { [weak self] in
                Paster.copyPlainText(text)
                self?.core.showMessage(
                    String(localized: "Couldn't paste into this app — copied instead."),
                    tone: .neutral)
            })
    }

    private func openCardInChat(chatID: UUID?, title: String, text: String) {
        persistTranscript()
        if let chatID, core.chatHistory.conversation(id: chatID) != nil {
            core.aiChatCoordinator.openChat(id: chatID)
            core.aiChatCoordinator.showWindow()
            return
        }
        core.aiChatCoordinator.continueQuickAction(prompt: title, reply: text, model: nil)
    }

    private func persistTranscript() {
        guard settings.aiEnabled, let chatID = activeChatID else { return }
        let messages: [ChatMessage] = transcript.entries.compactMap { entry in
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !entry.tools.isEmpty else { return nil }
            let uses = entry.tools.map { tool in
                ChatToolUse(
                    callID: tool.callID, origin: tool.origin, title: tool.title,
                    state: tool.isRunning ? .completed : (tool.isError ? .failed : .completed),
                    textOffset: tool.textOffset, sequence: tool.sequence)
            }
            return ChatMessage(
                id: entry.id, role: entry.role == .user ? .user : .assistant, text: text,
                state: .complete, sentAt: entry.sentAt, toolUses: uses)
        }
        guard !messages.isEmpty else { return }
        let chatSession = ChatSession(
            id: chatID, createdAt: activeChatCreatedAt, updatedAt: Date(), messages: messages,
            model: nil)
        core.chatHistory.save(chatSession)
        if !activeChatBound, let agent = activeAgent {
            core.agentStore.setAgent(agent.id, forChat: chatID)
            activeChatBound = true
        }
    }

    private func recordUsage(_ usage: LiveVoiceUsage, route: AIModelSelection) {
        let aiUsage = AIUsage(
            inputTokens: usage.input, outputTokens: usage.output, cachedInputTokens: usage.cached)
        guard aiUsage != AIUsage() else { return }
        UsageLedger.append(
            UsageLedgerEntry(at: Date(), origin: .voice, selection: route, usage: aiUsage))
    }

    // MARK: - Consent and context loading

    private func resolveScreenConsent(
        mode: LiveVoiceScreenMode, live: AIModelSelection, locator: AIModelSelection?
    ) async -> Bool? {
        guard mode != .off else { return false }
        guard ScreenRecordingAccess.isGranted else {
            core.showMessage(
                String(localized: "Screen Recording isn't allowed — starting Live Voice without screen access."),
                tone: .neutral)
            return false
        }
        let liveDestination = destinationName(for: live)
        var message = String(
            localized: """
                Screenshots of the display under your cursor will be sent to \(liveDestination) \
                during this session.
                """)
        if let locator {
            let locatorDestination = destinationName(for: locator)
            message += " " + String(
                localized: "Screen pointing also sends screenshots to \(locatorDestination).")
        }
        let choice = await core.choose(
            title: String(localized: "Share your screen with Live Voice?"),
            message: message,
            symbol: "display",
            options: [
                DialogAction(title: String(localized: "Share Screen")),
                DialogAction(title: String(localized: "Voice Only")),
                DialogAction(title: String(localized: "Cancel"), role: .cancel)
            ],
            defaultIndex: 0)
        switch choice {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    private func loadAgentPrompt(_ agent: AgentProfile?) async -> (persona: String, memory: String) {
        guard let agent else { return ("", "") }
        let memoryURL = core.agentStore.memoryURL(for: agent.id)
        let context = await Task.detached(priority: .userInitiated) {
            AgentContextLoader.load(agent, memoryURL: memoryURL)
        }.value
        var personaParts: [String] = []
        let own = agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { personaParts.append(own) }
        if let project = context.projectInstructions?.text { personaParts.append(project) }
        if let global = context.globalInstructions?.text { personaParts.append(global) }
        let persona = LiveVoiceRoutePolicy.boundedText(
            personaParts.joined(separator: "\n\n"), maxBytes: LiveVoiceRoutePolicy.maxPersonaBytes)
        let memory = LiveVoiceRoutePolicy.boundedText(
            context.memory, maxBytes: LiveVoiceRoutePolicy.maxMemoryBytes)
        return (persona, memory)
    }

    private func askEnableConsent(
        live: AIModelSelection, locator: AIModelSelection?,
        then approved: @escaping @MainActor () async -> Void
    ) {
        guard consentTask == nil else { return }
        let liveDestination = destinationName(for: live)
        var message = String(
            localized: """
                Starting Live Voice opens a real-time microphone stream to \(liveDestination). \
                Nothing is recorded until you start a session, and screen sharing is confirmed \
                each time.
                """)
        if let locator {
            let locatorDestination = destinationName(for: locator)
            message += " " + String(
                localized: "Screen pointing uses \(locatorDestination).")
        }
        consentTask = Task { [weak self] in
            guard let self else { return }
            defer { consentTask = nil }
            guard
                await core.confirm(
                    title: String(localized: "Enable Live Voice?"),
                    message: message,
                    symbol: CommandID.liveVoice.sfSymbol,
                    confirmTitle: String(localized: "Continue"),
                    tone: .neutral, confirmRole: .standard),
                !Task.isCancelled
            else { return }
            await approved()
        }
    }

    private func askSwitchConsent(
        to selection: AIModelSelection, forPointer: Bool,
        then approved: @escaping @MainActor () -> Void
    ) {
        guard consentTask == nil, case .api(let id, let model, _) = selection,
            let connection = aiSettings.connection(id: id)
        else { return }
        let title =
            forPointer
            ? String(localized: "Send screen pointing to \(connection.title)?")
            : String(localized: "Send Live Voice to \(connection.title)?")
        let message =
            forPointer
            ? String(
                localized: """
                    Screen pointing will send screenshots to \(connection.title) using \(model) \
                    when you share your screen in a Live Voice session.
                    """)
            : String(
                localized: """
                    Live Voice will stream your microphone to \(connection.title) using \(model) \
                    when you start a session.
                    """)
        consentTask = Task { [weak self] in
            guard let self else { return }
            defer { consentTask = nil }
            guard
                await core.confirm(
                    title: title, message: message, symbol: CommandID.liveVoice.sfSymbol,
                    confirmTitle: String(localized: "Continue"), tone: .neutral,
                    confirmRole: .standard),
                !Task.isCancelled
            else { return }
            approved()
        }
    }

    // MARK: - Helpers

    private func destinationName(for selection: AIModelSelection) -> String {
        guard case .api(let id, let model, _) = selection,
            let connection = aiSettings.connection(id: id)
        else { return selection.model }
        return "\(connection.title) (\(model))"
    }

    private func provider(of selection: AIModelSelection?) -> LiveVoiceProvider? {
        guard case .api(let id, _, _) = selection, let connection = aiSettings.connection(id: id)
        else { return nil }
        return LiveVoiceRoutePolicy.provider(for: connection)
    }

    private func isRouteEnabled(_ id: UUID) -> Bool { aiSettings.isRouteEnabled(.api(id)) }

    private func externalTargetApp() -> NSRunningApplication? {
        let palette = core.paletteCoordinator
        let candidate = palette.isVisible ? palette.targetApp : NSWorkspace.shared.frontmostApplication
        guard let candidate, candidate.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        return candidate
    }

    private func toolStatusLabel(for name: String) -> String {
        switch name {
        case LiveVoiceToolName.look: String(localized: "Looking at screen…")
        case LiveVoiceToolName.point: String(localized: "Finding on screen…")
        case LiveVoiceToolName.show: String(localized: "Showing text…")
        case LiveVoiceToolName.task: String(localized: "Starting task…")
        default: String(localized: "Running \(name)…")
        }
    }

    private func capsuleInstance() -> LiveVoiceCapsuleController {
        if let capsule { return capsule }
        let capsule = LiveVoiceCapsuleController()
        capsule.onInterrupt = { [weak self] in self?.session?.interrupt() }
        capsule.onToggleMute = { [weak self] in
            guard let self, let capsule = self.capsule else { return }
            let next = !capsule.state.isMuted
            capsule.state.isMuted = next
            self.session?.setMuted(next)
            if next {
                capsule.state.phase = .muted
            } else if capsule.state.phase == .muted {
                capsule.state.phase = .listening
            }
        }
        capsule.onClose = { [weak self] in self?.stop() }
        self.capsule = capsule
        return capsule
    }

    private func pointerInstance() -> LiveVoicePointerController {
        if let pointer { return pointer }
        let pointer = LiveVoicePointerController()
        self.pointer = pointer
        return pointer
    }
}
