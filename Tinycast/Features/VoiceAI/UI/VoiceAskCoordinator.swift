import AppKit
import AVFoundation

/// The one funnel for Ask by Voice: shortcut, launcher row, capsule keys and panel all end here.
@MainActor
final class VoiceAskCoordinator {
    private enum Phase { case idle, starting, listening, replying }

    private struct Session {
        let app: NSRunningApplication
        let selection: AIModelSelection
        let provider: any AIProvider
        let wantsScreenshot: Bool
        let screen: Task<ScreenAwarenessCoordinator.Capture?, Never>
    }

    /// What the panel keeps once the session is over: the question, its app, model and capture.
    private struct Asked {
        let question: String?
        let app: NSRunningApplication
        let selection: AIModelSelection
        let screen: String
    }

    private static let panelActionID = UUID(uuidString: "6F1C7A52-3B9E-4D0A-9C1E-5A1F00A0B0CE") ?? UUID()

    private let settings: AppSettings
    private let voice: VoiceAISettings
    private let aiSettings: AISettingsStore
    private let appIndex: AppIndex
    private let hotKeys: HotKeyManager
    private let injector: TextInjector
    private let audioDucker: DictationAudioDucker
    private unowned let core: AppCore

    /// Built on the first press, so no capture session, panel or view exists before one.
    private var recorder: DictationCapture?
    private var capsule: DictationPanelController?
    private var panels: QuickActionPanelController?
    private var phase = Phase.idle
    private var token = UUID()
    private var finishWhenStarted = false
    private var session: Session?
    private var work: Task<Void, Never>?
    /// Every start waits for the last stop: one recorder must never run two sessions at once.
    private var stopping: Task<Void, Never>?
    private var enableTask: Task<Void, Never>?

    init(
        settings: AppSettings, voice: VoiceAISettings, aiSettings: AISettingsStore,
        appIndex: AppIndex, hotKeys: HotKeyManager, injector: TextInjector,
        audioDucker: DictationAudioDucker, core: AppCore
    ) {
        self.settings = settings
        self.voice = voice
        self.aiSettings = aiSettings
        self.appIndex = appIndex
        self.hotKeys = hotKeys
        self.injector = injector
        self.audioDucker = audioDucker
        self.core = core
    }

    var isActive: Bool { settings.aiEnabled && settings.screenAwarenessEnabled && voice.askEnabled }

    var selection: AIModelSelection? {
        VoiceRoutePolicy.resolve(
            voice.askModel, use: .ask, connections: aiSettings.connections,
            isEnabled: { [aiSettings] in aiSettings.isRouteEnabled(.api($0)) })
    }

    /// Carbon reports a release only for a key combination; any other binding acts as a toggle.
    var holdShortcutIssue: String? {
        guard voice.askMode == .pushToTalk,
            let binding = hotKeys.binding(for: .command(.askByVoice)), binding.shortcut == nil
        else { return nil }
        return String(
            localized: """
                Hold to talk needs a key combination. Double taps and single modifiers start and stop \
                instead.
                """)
    }

    private var holdsToTalk: Bool {
        voice.askMode == .pushToTalk && hotKeys.binding(for: .command(.askByVoice))?.shortcut != nil
    }

    /// The row leaves the launcher with the switch; the Carbon binding stays, and does nothing.
    func applyEnabled() {
        appIndex.setCommandsVisible([.askByVoice], isActive)
        if !isActive { cancel() }
    }

    /// Enabling is consent, then the microphone, then Accessibility, each asked for here only.
    func setEnabled(_ enabled: Bool) {
        guard enabled != voice.askEnabled else { return }
        guard enabled else {
            enableTask?.cancel()
            voice.askEnabled = false
            return
        }
        guard enableTask == nil, case .api(let id, _, _) = selection,
            let connection = aiSettings.connection(id: id)
        else { return }
        NSApp.activate()
        enableTask = Task { [weak self] in
            guard let self else { return }
            defer { enableTask = nil }
            guard
                await core.confirm(
                    title: String(localized: "Enable Ask by Voice?"),
                    message: String(
                        localized: """
                            A shortcut records your question and sends it, with the window in front \
                            of you, to \(connection.title). Nothing is recorded or read until you \
                            press it.
                            """),
                    symbol: CommandID.askByVoice.sfSymbol, confirmTitle: String(localized: "Continue"),
                    tone: .neutral, confirmRole: .standard),
                !Task.isCancelled
            else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard !Task.isCancelled else { return }
            guard granted else {
                core.showMessage(
                    String(localized: "Allow Tinycast to use the microphone in System Settings"),
                    tone: .danger)
                return
            }
            voice.askEnabled = true
            Permissions.ensureAccessibility()
        }
    }

    func pressed() {
        guard isActive else { return }
        switch phase {
        case .starting: finishWhenStarted = true
        case .listening: accept()
        case .replying:
            cancel()
            begin()
        case .idle: begin()
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
        enableTask?.cancel()
        let recording = phase == .starting || phase == .listening
        cancel()
        if recording { audioDucker.restoreImmediately() }
    }

    // MARK: - Recording

    private func begin() {
        if settings.dictationEnabled, core.dictationCoordinator.isBusy {
            core.showMessage(VoiceAIFailure.dictationBusy.localizedDescription, tone: .neutral)
            return
        }
        let screenAwareness = core.screenAwarenessCoordinator
        guard let app = screenAwareness.captureTarget() else { return }
        guard Permissions.isAccessibilityTrusted() else {
            screenAwareness.reportMissingAccessibility()
            return
        }
        guard let selection else {
            core.showMessage(VoiceAIFailure.noAskModel.localizedDescription, tone: .danger)
            return
        }
        let provider: any AIProvider
        do {
            provider = try VoiceAIRoute.provider(for: selection, settings: aiSettings)
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
        let wantsScreenshot = settings.screenAwarenessScreenshot && takesImages(selection)
        session = Session(
            app: app, selection: selection, provider: provider, wantsScreenshot: wantsScreenshot,
            screen: Task { await screenAwareness.capture(app, screenshot: wantsScreenshot) })
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
        work = Task { [weak self] in await self?.reply(session, wav: wav, token: current) }
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

    private func reply(_ session: Session, wav: Task<Data?, Never>, token current: UUID) async {
        let wav = await wav.value
        guard token == current else { return }
        guard let wav else { return finish(failing: VoiceAIFailure.noSpeech.localizedDescription) }
        let capture = await session.screen.value
        guard token == current else { return }
        guard let capture else { return endSession() }
        let jpeg: Data? =
            if let png = capture.screenshot { await VoiceMediaEncoder.jpeg(fromPNG: png) } else { nil }
        guard token == current else { return }
        if session.wantsScreenshot, capture.screenshot == nil, !ScreenRecordingAccess.isGranted {
            core.showMessage(
                String(localized: "No screenshot: allow Screen Recording for Tinycast in System Settings."),
                tone: .neutral)
        }
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
            Asked(question: question, app: session.app, selection: session.selection, screen: screen)
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

    // MARK: - Surfaces

    @discardableResult
    private func present(_ asked: Asked) -> QuickActionPanelState {
        let action = CustomQuickAction(
            id: Self.panelActionID,
            name: asked.question.map(VoiceReplyParser.title) ?? CommandID.askByVoice.name,
            iconSymbol: "waveform", instructions: "", previewsResult: true, createdAt: .distantPast)
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
                        prompt: VoicePrompt.chatPrompt(question: asked.question, screen: asked.screen),
                        reply: reply, model: asked.selection)
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
        session?.screen.cancel()
        session = nil
        phase = .idle
        finishWhenStarted = false
        capsule?.close()
    }

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
