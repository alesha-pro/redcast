import AppKit
import AVFoundation

/// The one funnel for Ask by Voice and Edit Selection by Voice: shortcuts, rows, capsule, panel.
@MainActor
final class VoiceAskCoordinator {
    private enum Phase { case idle, starting, listening, replying }

    /// What a recording is for, and what is read while the reader speaks.
    private enum Purpose {
        /// With an agent, the request is only transcribed and runs as its background task.
        case ask(
            screen: Task<ScreenAwarenessCoordinator.Capture?, Never>, wantsScreenshot: Bool,
            agent: AgentProfile?)
        /// The selected text, or nil once a refusal has ended the session and said why.
        case edit(selection: Task<String?, Never>)
    }

    private struct Session {
        let app: NSRunningApplication
        let route: AIModelSelection
        let provider: any AIProvider
        let purpose: Purpose
    }

    /// What the panel keeps once the session is over: its title, the app, the route, the chat seed.
    private struct Asked {
        let question: String?
        let command: CommandID
        let app: NSRunningApplication
        let route: AIModelSelection
        let chatPrompt: String
    }

    static let commands: Set<CommandID> = [.askByVoice, .editByVoice]

    private static let panelActionID = UUID(uuidString: "6F1C7A52-3B9E-4D0A-9C1E-5A1F00A0B0CE") ?? UUID()

    private let settings: AppSettings
    private let voice: VoiceAISettings
    private let aiSettings: AISettingsStore
    private let appIndex: AppIndex
    private let hotKeys: HotKeyManager
    private let injector: TextInjector
    private let audioDucker: DictationAudioDucker
    private let requestMicrophone: @MainActor () async -> Bool
    private unowned let core: AppCore

    /// Built on the first press, so no capture session, panel or view exists before one.
    private var recorder: DictationCapture?
    private var capsule: DictationPanelController?
    private var panels: QuickActionPanelController?
    private var phase = Phase.idle
    private var token = UUID()
    private var finishWhenStarted = false
    private var session: Session?
    private var command = CommandID.askByVoice
    private var work: Task<Void, Never>?
    /// Every start waits for the last stop: one recorder must never run two sessions at once.
    private var stopping: Task<Void, Never>?
    private var consentTask: Task<Void, Never>?

    init(
        settings: AppSettings, voice: VoiceAISettings, aiSettings: AISettingsStore,
        appIndex: AppIndex, hotKeys: HotKeyManager, injector: TextInjector,
        audioDucker: DictationAudioDucker, core: AppCore,
        requestMicrophone: @escaping @MainActor () async -> Bool = {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
    ) {
        self.settings = settings
        self.voice = voice
        self.aiSettings = aiSettings
        self.appIndex = appIndex
        self.hotKeys = hotKeys
        self.injector = injector
        self.audioDucker = audioDucker
        self.requestMicrophone = requestMicrophone
        self.core = core
    }

    var isActive: Bool { settings.aiEnabled && settings.screenAwarenessEnabled && voice.askEnabled }

    /// The only destination a question goes to: the one consented to, never a substitute.
    var route: AIModelSelection? {
        VoiceRoutePolicy.route(
            voice.askModel, use: .ask, connections: aiSettings.connections, isEnabled: isRouteEnabled)
    }

    /// The agent a question goes to while it still exists; nil answers with the model.
    var agent: AgentProfile? {
        guard let id = voice.askAgent else { return nil }
        return core.agentCoordinator.agents.first { $0.id == id }
    }

    /// What enabling names; nil while no connection hears audio, which keeps the switch disabled.
    var proposal: AIModelSelection? {
        VoiceRoutePolicy.proposal(
            voice.askModel, use: .ask, connections: aiSettings.connections, isEnabled: isRouteEnabled)
    }

    /// A key combination or a single modifier is held; a double tap acts as a toggle.
    var holdShortcutIssue: String? {
        guard voice.askMode == .pushToTalk else { return nil }
        for command in [CommandID.askByVoice, .editByVoice] {
            guard let binding = hotKeys.binding(for: .command(command)) else { continue }
            guard binding.shortcut != nil || binding.holdKey != nil else {
                return String(
                    localized: """
                        Hold to talk needs a key combination or a single modifier. A double tap starts \
                        and stops instead.
                        """)
            }
            if binding.holdKey != nil,
                let owner = hotKeys.conflictOwner(of: binding, excluding: .command(command))
            {
                return String(localized: "This shortcut is also used by \(owner). Record another shortcut.")
            }
        }
        return nil
    }

    private var holdsToTalk: Bool {
        guard voice.askMode == .pushToTalk, let binding = hotKeys.binding(for: .command(command))
        else { return false }
        return binding.shortcut != nil || binding.holdKey != nil
    }

    /// Hold to talk takes a single modifier through the shared tap, only while that is the mode.
    func applyHoldMode() {
        hotKeys.heldCommands = voice.askMode == .pushToTalk ? Self.commands : []
    }

    /// The rows leave the launcher with the switch; the Carbon bindings stay, and do nothing.
    func applyEnabled() {
        appIndex.setCommandsVisible(Self.commands, isActive)
        if !isActive { cancel() }
    }

    /// Enabling is consent, then the microphone, then Accessibility, each asked for here only.
    func setEnabled(_ enabled: Bool) {
        guard enabled != voice.askEnabled else { return }
        guard enabled else {
            consentTask?.cancel()
            voice.askEnabled = false
            return
        }
        guard let proposal else { return }
        NSApp.activate()
        askConsent(to: proposal, switching: false) { [weak self] in
            guard let self else { return }
            let granted = await requestMicrophone()
            guard !Task.isCancelled else { return }
            guard granted else {
                core.showMessage(
                    String(localized: "Allow Tinycast to use the microphone in System Settings"),
                    tone: .danger)
                return
            }
            voice.askModel = proposal
            voice.askEnabled = true
            Permissions.ensureAccessibility()
        }
    }

    /// Another connection is another destination, so while on it is asked for like the switch.
    func choose(_ selection: AIModelSelection) {
        guard voice.askEnabled, selection.source != route?.source else {
            voice.askModel = selection
            return
        }
        askConsent(to: selection, switching: true) { [voice] in voice.askModel = selection }
    }

    /// The dialog names the connection and model; only an approval still current runs `approved`.
    private func askConsent(
        to selection: AIModelSelection, switching: Bool,
        then approved: @escaping @MainActor () async -> Void
    ) {
        guard consentTask == nil, case .api(let id, let model, _) = selection,
            let connection = aiSettings.connection(id: id)
        else { return }
        let title =
            switching
            ? String(localized: "Send Ask by Voice to \(connection.title)?")
            : String(localized: "Enable Ask by Voice?")
        consentTask = Task { [weak self] in
            guard let self else { return }
            defer { consentTask = nil }
            guard
                await core.confirm(
                    title: title,
                    message: String(
                        localized: """
                            A shortcut records your request and sends it, with the window in front of \
                            you or the text you selected, to \(connection.title) to be answered by \
                            \(model). Nothing is recorded or read until you press it.
                            """),
                    symbol: CommandID.askByVoice.sfSymbol, confirmTitle: String(localized: "Continue"),
                    tone: .neutral, confirmRole: .standard),
                !Task.isCancelled
            else { return }
            await approved()
        }
    }

    /// Either command's press: a second one, of either, finishes the recording.
    func pressed(_ command: CommandID = .askByVoice) {
        guard isActive else { return }
        switch phase {
        case .starting: finishWhenStarted = true
        case .listening: accept()
        case .replying:
            cancel()
            begin(command)
        case .idle: begin(command)
        }
    }

    func released() {
        guard holdsToTalk else { return }
        if phase == .starting { finishWhenStarted = true }
        if phase == .listening { accept() }
    }

    func cancel() {
        guard phase != .idle else { return }
        let recording = phase == .starting || phase == .listening
        let pendingStart = work
        token = UUID()
        work?.cancel()
        work = nil
        panels?.dismiss()
        endSession()
        if recording { _ = stopRecording(after: pendingStart) }
    }

    func prepareForTermination() {
        consentTask?.cancel()
        let recording = phase == .starting || phase == .listening
        cancel()
        if recording { audioDucker.restoreImmediately() }
    }

    // MARK: - Recording

    private func begin(_ command: CommandID) {
        if settings.dictationEnabled, core.dictationCoordinator.isBusy {
            core.showMessage(VoiceAIFailure.dictationBusy.localizedDescription, tone: .neutral)
            return
        }
        let screenAwareness = core.screenAwarenessCoordinator
        let target = command == .editByVoice ? editTarget() : screenAwareness.captureTarget()
        guard let app = target else { return }
        guard command == .editByVoice || Permissions.isAccessibilityTrusted() else {
            screenAwareness.reportMissingAccessibility()
            return
        }
        guard let route else {
            core.showMessage(VoiceAIFailure.noAskModel.localizedDescription, tone: .danger)
            return
        }
        let agent = command == .askByVoice ? agent : nil
        if let agent, let refusal = refusal(of: agent) {
            core.showMessage(refusal, tone: .neutral)
            return
        }
        let provider: any AIProvider
        do {
            provider = try VoiceAIRoute.provider(for: route, settings: aiSettings)
        } catch {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        if core.paletteCoordinator.isVisible { core.paletteCoordinator.hidePalette(restoreFocus: true) }
        panels?.dismiss()
        token = UUID()
        let current = token
        phase = .starting
        finishWhenStarted = false
        self.command = command
        let purpose: Purpose
        if command == .editByVoice {
            purpose = .edit(selection: readSelection(in: app, token: current))
        } else {
            // An agent's own model decides on the picture; this route never sees the window then.
            let wantsScreenshot = settings.screenAwarenessScreenshot && (agent != nil || takesImages(route))
            purpose = .ask(
                screen: Task { await screenAwareness.capture(app, screenshot: wantsScreenshot) },
                wantsScreenshot: wantsScreenshot, agent: agent)
        }
        session = Session(app: app, route: route, provider: provider, purpose: purpose)
        audioDucker.begin()
        let recorder = recorderInstance()
        let previousStop = stopping
        work = Task { [weak self] in
            _ = await previousStop?.value
            do {
                try await recorder.start(microphoneID: self?.settings.dictationMicrophone)
                guard let self, token == current else { return }
                phase = .listening
                capsuleInstance().show()
                if finishWhenStarted { accept() }
            } catch {
                guard let self, token == current else { return }
                cancel()
                core.showMessage(error.localizedDescription, tone: .danger)
            }
        }
    }

    private func accept() {
        guard phase == .listening, let session else { return }
        phase = .replying
        capsule?.state.phase = .transcribing
        audioDucker.end()
        let samples = stopRecording(after: nil)
        // Its own task, so the samples are freed once encoded rather than held through the reply.
        let wav = Task { await VoiceMediaEncoder.wav(await samples.value) }
        let current = token
        work = Task { [weak self] in
            switch session.purpose {
            case .ask(let reading, let wantsScreenshot, nil):
                await self?.reply(
                    session, reading: reading, wantsScreenshot: wantsScreenshot, wav: wav, token: current)
            case .ask(let reading, let wantsScreenshot, let agent?):
                await self?.handOff(
                    session, to: agent, reading: reading, wantsScreenshot: wantsScreenshot, wav: wav,
                    token: current)
            case .edit(let selection):
                await self?.edit(session, selection: selection, wav: wav, token: current)
            }
        }
    }

    /// The app in front, or behind the palette; Tinycast's own windows have nothing to edit here.
    private func editTarget() -> NSRunningApplication? {
        let palette = core.paletteCoordinator
        let app = palette.isVisible ? palette.targetApp : NSWorkspace.shared.frontmostApplication
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            core.showMessage(QuickActionFailure.noTarget.localizedDescription, tone: .neutral)
            return nil
        }
        return app
    }

    /// Read as Quick Actions read it, while the reader speaks; a refusal ends the session at once.
    private func readSelection(in app: NSRunningApplication, token current: UUID) -> Task<String?, Never> {
        Task { [weak self, injector] in
            do {
                return try await QuickActionRunner.selection(in: app, using: injector)
            } catch {
                guard let self, token == current else { return nil }
                cancel()
                core.showMessage(error.localizedDescription, tone: .danger)
                return nil
            }
        }
    }

    private func stopRecording(after pendingStart: Task<Void, Never>?) -> Task<[Float], Never> {
        let previous = stopping
        let recorder = recorder
        let stop = Task {
            await pendingStart?.value
            await previous?.value
            return await recorder?.stop() ?? []
        }
        stopping = Task { _ = await stop.value }
        return stop
    }

    // MARK: - Reply

    private func reply(
        _ session: Session, reading: Task<ScreenAwarenessCoordinator.Capture?, Never>, wantsScreenshot: Bool,
        wav: Task<Data?, Never>, token current: UUID
    ) async {
        let wav = await wav.value
        guard token == current else { return }
        guard let wav else { return finish(failing: VoiceAIFailure.noSpeech.localizedDescription) }
        let capture = await reading.value
        guard token == current else { return }
        guard let capture else { return endSession() }
        let jpeg: Data? =
            if let png = capture.screenshot { await VoiceMediaEncoder.jpeg(fromPNG: png) } else { nil }
        guard token == current else { return }
        reportMissingScreenshot(wanted: wantsScreenshot, capture)
        let screen = ScreenContextFormatter.markdown(
            capture.context, maxBytes: AIAttachmentBudget.maxInlinedTextBytes, timeZone: .current,
            hasScreenshot: jpeg != nil)
        let focused = capture.context.focusedField != nil
        let request = VoicePrompt.askRequest(
            audio: AIAudio(data: wav, format: "wav"), screen: screen,
            image: jpeg.map { AIImage(data: $0, mimeType: "image/jpeg") }, hasFocusedField: focused,
            vocabulary: voice.vocabulary)
        var reply = VoiceReplySession(bundleID: session.app.bundleIdentifier, hadFocusedField: focused)
        var panel: QuickActionPanelState?
        let asked = { (question: String?) in
            Asked(
                question: question, command: .askByVoice, app: session.app, route: session.route,
                chatPrompt: VoicePrompt.chatPrompt(question: question, screen: screen))
        }
        do {
            for try await event in session.provider.stream(request) {
                guard token == current else { return }
                guard case .text(let delta) = event else { continue }
                show(reply.feed(delta), in: &panel, asked: asked)
            }
            try Task.checkCancellation()
            guard token == current else { return }
            let (steps, outcome) = reply.finish()
            show(steps, in: &panel, asked: asked)
            complete(outcome, panel: panel, asked: asked(reply.question))
        } catch is CancellationError {
            return
        } catch {
            guard token == current else { return }
            if let panel {
                panel.fail(error.localizedDescription)
                endSession()
            } else {
                finish(failing: error.localizedDescription)
            }
        }
    }

    private func show(
        _ steps: [VoiceReplySession.Step], in panel: inout QuickActionPanelState?,
        asked: (String?) -> Asked
    ) {
        for step in steps {
            switch step {
            case .open(let question, let text):
                capsule?.close()
                let opened = present(asked(question))
                opened.append(text)
                panel = opened
            case .append(let text):
                panel?.append(text)
            }
        }
    }

    private func complete(
        _ outcome: VoiceReplySession.Outcome, panel: QuickActionPanelState?, asked: Asked
    ) {
        endSession()
        switch outcome {
        case .noSpeech:
            panels?.dismiss()
            core.showMessage(VoiceAIFailure.noSpeech.localizedDescription, tone: .danger)
        case .answer(let text): (panel ?? present(asked)).finish(text)
        case .review(let text): present(asked).finish(text)
        case .insert(let text): deliver(text, for: asked)
        }
    }

    /// Missing permission is worth one line; a capture that simply had no picture is not.
    private func reportMissingScreenshot(wanted: Bool, _ capture: ScreenAwarenessCoordinator.Capture) {
        guard wanted, capture.screenshot == nil, !ScreenRecordingAccess.isGranted else { return }
        core.showMessage(
            String(localized: "No screenshot: allow Screen Recording for Tinycast in System Settings."),
            tone: .neutral)
    }

    // MARK: - Agent

    /// Asked before recording, so a request that could not run is never sent to be transcribed.
    private func refusal(of agent: AgentProfile) -> String? {
        guard let runs = core.agentCoordinator.runs else { return nil }
        if runs.isBusy(agent: agent.id) {
            return String(localized: "\(agent.name) is still working on another task")
        }
        guard runs.activeCount < AgentBackgroundCoordinator.maxConcurrent else {
            return String(localized: "Three agents are already running")
        }
        return nil
    }

    /// Transcribed on the consented route, then run exactly as `@handle request` would be.
    private func handOff(
        _ session: Session, to agent: AgentProfile, reading: Task<ScreenAwarenessCoordinator.Capture?, Never>,
        wantsScreenshot: Bool, wav: Task<Data?, Never>, token current: UUID
    ) async {
        let wav = await wav.value
        guard token == current else { return }
        guard let wav else { return finish(failing: VoiceAIFailure.noSpeech.localizedDescription) }
        let capture = await reading.value
        guard token == current else { return }
        guard let capture else { return endSession() }
        reportMissingScreenshot(wanted: wantsScreenshot, capture)
        let request = VoicePrompt.agentRequest(
            audio: AIAudio(data: wav, format: "wav"), vocabulary: voice.vocabulary)
        var text = ""
        do {
            for try await event in session.provider.stream(request) {
                guard token == current else { return }
                if case .text(let delta) = event { text += delta }
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            guard token == current else { return }
            return finish(failing: error.localizedDescription)
        }
        guard token == current else { return }
        guard let task = VoiceTranscript.cleaned(text) else {
            return finish(failing: VoiceAIFailure.noSpeech.localizedDescription)
        }
        endSession()
        core.agentCoordinator.background.start(
            task, with: agent, attachments: core.screenAwarenessCoordinator.attachments(for: capture))
    }

    // MARK: - Edit

    private func edit(
        _ session: Session, selection: Task<String?, Never>, wav: Task<Data?, Never>, token current: UUID
    ) async {
        let wav = await wav.value
        guard token == current else { return }
        guard let wav else { return finish(failing: VoiceAIFailure.noSpeech.localizedDescription) }
        let original = await selection.value
        guard token == current, let original else { return }
        let request = VoicePrompt.editRequest(
            audio: AIAudio(data: wav, format: "wav"), selection: original, vocabulary: voice.vocabulary)
        var reply = VoiceEditReply()
        do {
            for try await event in session.provider.stream(request) {
                guard token == current else { return }
                if case .text(let delta) = event { reply.feed(delta) }
            }
            try Task.checkCancellation()
            guard token == current else { return }
            guard case .edited(let text, let instruction) = reply.finish(original: original) else {
                return finish(failing: VoiceAIFailure.noSpeech.localizedDescription)
            }
            endSession()
            let asked = Asked(
                question: instruction, command: .editByVoice, app: session.app, route: session.route,
                chatPrompt: VoicePrompt.editChatPrompt(instruction: instruction, selection: original))
            await replace(original, with: text, asked: asked)
        } catch is CancellationError {
            return
        } catch {
            guard token == current else { return }
            finish(failing: error.localizedDescription)
        }
    }

    /// Replaced only while the same text is still selected and writable, and never in a terminal.
    private func replace(_ original: String, with text: String, asked: Asked) async {
        let current = token
        guard VoiceInsertPolicy.replacesUnseen(bundleID: asked.app.bundleIdentifier),
            VoiceSelectionAccess.isWritable(in: asked.app)
        else { return present(asked).finish(text) }
        let now = try? await QuickActionRunner.selection(in: asked.app, using: injector)
        guard token == current else { return }
        guard let now, VoiceEditReply.isSameSelection(original, now) else {
            present(asked).finish(text)
            core.showMessage(
                String(localized: "The selection changed, so the result is shown instead."), tone: .neutral)
            return
        }
        injector.replaceSelection(
            with: text, in: asked.app,
            onFailed: { [weak self] in
                guard let self, token == current else { return }
                present(asked).finish(text)
                core.showMessage(
                    String(localized: "Couldn't replace the selection — the result is shown instead."),
                    tone: .danger)
            })
    }

    // MARK: - Surfaces

    @discardableResult
    private func present(_ asked: Asked) -> QuickActionPanelState {
        let action = CustomQuickAction(
            id: Self.panelActionID,
            name: asked.question.map(VoiceReplyParser.title) ?? asked.command.name,
            iconSymbol: asked.command == .editByVoice ? asked.command.sfSymbol : "waveform", instructions: "",
            previewsResult: true, createdAt: .distantPast)
        let state = QuickActionPanelState(
            action: .custom(action), original: asked.question ?? "",
            targetLanguage: Locale.current.language)
        let panels = panels ?? QuickActionPanelController()
        self.panels = panels
        let current = token
        panels.present(
            state, metrics: settings.interfaceSize.metrics, languages: [], onRetranslate: { _ in },
            onReplace: { [weak self] text in self?.deliver(text, for: asked) },
            onContinueInChat: settings.aiEnabled
                ? { [weak self] reply in
                    self?.core.aiChatCoordinator.continueQuickAction(
                        prompt: asked.chatPrompt, reply: reply, model: asked.route)
                } : nil,
            onDismiss: { [weak self] in
                guard let self, token == current, phase == .replying else { return }
                cancel()
            })
        return state
    }

    /// Typed at the caret, or over the selection, of the app the question was asked in.
    private func deliver(_ text: String, for asked: Asked) {
        let current = token
        injector.deliver(
            InjectedText(text), target: .external(asked.app), expectedKeyword: nil, keywordLength: 0,
            automaticGeneration: nil, isValid: { [weak self] in self?.token == current },
            onFailed: { [weak self] in
                guard let self, token == current else { return }
                present(asked).finish(text)
                core.showMessage(
                    String(localized: "Couldn't type into this app — the reply is shown instead."),
                    tone: .danger)
            })
    }

    private func finish(failing message: String) {
        endSession()
        core.showMessage(message, tone: .danger)
    }

    /// Back to idle; an answer already on screen stays there.
    private func endSession() {
        if phase == .starting || phase == .listening { audioDucker.end() }
        if case .ask(let reading, _, _)? = session?.purpose { reading.cancel() }
        session = nil
        phase = .idle
        finishWhenStarted = false
        capsule?.close()
    }

    private func isRouteEnabled(_ id: UUID) -> Bool { aiSettings.isRouteEnabled(.api(id)) }

    private func takesImages(_ selection: AIModelSelection) -> Bool {
        guard case .api(let id, let model, _) = selection, let connection = aiSettings.connection(id: id)
        else { return false }
        return VoiceRoutePolicy.takesImages(connection, model: model)
    }

    private func recorderInstance() -> DictationCapture {
        if let recorder { return recorder }
        let recorder = DictationCapture()
        recorder.onLevels = { [weak self] in self?.capsule?.state.levels = $0 }
        recorder.onLimit = { [weak self] in self?.accept() }
        self.recorder = recorder
        return recorder
    }

    private func capsuleInstance() -> DictationPanelController {
        if let capsule { return capsule }
        let capsule = DictationPanelController()
        capsule.onAccept = { [weak self] in self?.accept() }
        capsule.onCancel = { [weak self] in self?.cancel() }
        self.capsule = capsule
        return capsule
    }
}
