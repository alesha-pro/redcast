import AppKit

/// The cloud engine behind the Dictation shortcut; capture, panel and insertion stay Dictation's.
@MainActor
final class VoiceCloudTranscriber {
    /// A finished transcript and how it was made, which Dictation History records.
    struct Transcription: Equatable {
        let text: String
        /// What the model heard, when a mode's second request rewrote it.
        let transcript: String?
        let mode: String?
        let model: String
    }

    private let settings: AppSettings
    private let voice: VoiceAISettings
    private let aiSettings: AISettingsStore
    private let confirm: (_ title: String, _ message: String) async -> Bool
    private let frontmostBundleID: @MainActor () -> String?
    /// The app Dictation types into; nil for one of Tinycast's own editors, such as a Note.
    private let dictatedApp: @MainActor () -> NSRunningApplication?
    private var consentTask: Task<Void, Never>?
    private weak var capsule: DictationPanelController?
    /// While the capsule is up: the app it opened over, its frame, and the mode it names.
    private var session: (bundleID: String?, frame: NSRect)?
    private(set) var activeMode: VoiceMode?
    /// The app dictated into, read off-main as the capsule shows; a sent recording waits only briefly.
    private var frontApp: Task<VoiceAppContext?, Never>?
    /// How long a finished recording waits for a capture still running before going without it.
    private static let contextGrace: Duration = .milliseconds(500)
    private var caption: VoiceModeCaption?
    /// Read while the capsule is still up, and gone with it.
    private(set) var lastTranscription: Transcription?

    init(
        settings: AppSettings, voice: VoiceAISettings, aiSettings: AISettingsStore,
        confirm: @escaping (_ title: String, _ message: String) async -> Bool,
        frontmostBundleID: @escaping @MainActor () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        dictatedApp: @escaping @MainActor () -> NSRunningApplication?
    ) {
        self.settings = settings
        self.voice = voice
        self.aiSettings = aiSettings
        self.confirm = confirm
        self.frontmostBundleID = frontmostBundleID
        self.dictatedApp = dictatedApp
    }

    var isOn: Bool { settings.dictationEnabled && voice.cloudDictation }

    /// The only destination a recording goes to: the one consented to, never a substitute.
    var route: AIModelSelection? {
        VoiceRoutePolicy.route(
            voice.dictationModel, use: .dictation, connections: aiSettings.connections,
            isEnabled: isRouteEnabled)
    }

    /// What the switch's dialog names; nil while no connection hears audio, keeping it disabled.
    var proposal: AIModelSelection? {
        VoiceRoutePolicy.proposal(
            voice.dictationModel, use: .dictation, connections: aiSettings.connections,
            isEnabled: isRouteEnabled)
    }

    /// Turning it on is consent: the dialog names the destination, and approval saves that one.
    func setEnabled(_ enabled: Bool) {
        guard enabled != voice.cloudDictation else { return }
        guard enabled else {
            consentTask?.cancel()
            voice.cloudDictation = false
            return
        }
        guard let proposal else { return }
        askConsent(to: proposal, switching: false)
    }

    /// Another connection is another destination, so while on it is asked for like the switch.
    func choose(_ selection: AIModelSelection) {
        guard voice.cloudDictation, selection.source != route?.source else {
            voice.dictationModel = selection
            return
        }
        askConsent(to: selection, switching: true)
    }

    private func askConsent(to selection: AIModelSelection, switching: Bool) {
        guard consentTask == nil, case .api(let id, let model, _) = selection,
            let connection = aiSettings.connection(id: id)
        else { return }
        let title =
            switching
            ? String(localized: "Send Dictation to \(connection.title)?")
            : String(localized: "Transcribe Dictation in the Cloud?")
        let message =
            voice.appContext == .off
            ? String(
                localized: """
                    Each finished recording goes to \(connection.title) to be transcribed by \
                    \(model). Tinycast keeps a copy of the audio only when transcription fails, for \
                    at most a week; your provider's data policy applies.
                    """)
            : String(
                localized: """
                    Each finished recording goes to \(connection.title) to be transcribed by \
                    \(model), with the name and window title of the app you dictate into, and a \
                    screenshot if you chose one. Tinycast keeps a copy only when transcription fails, \
                    for at most a week; your provider's data policy applies.
                    """)
        consentTask = Task { [weak self] in
            guard let self else { return }
            defer { consentTask = nil }
            let approved = await confirm(title, message)
            guard approved, !Task.isCancelled else { return }
            voice.dictationModel = selection
            voice.cloudDictation = true
        }
    }

    // MARK: - Modes

    /// The capsule's hooks, set once; they act only while cloud transcription is on.
    func attach(to capsule: DictationPanelController) {
        self.capsule = capsule
        capsule.onPlacement = { [weak self] in self?.capsuleMoved(to: $0) }
        capsule.onTab = { [weak self] in self?.switchMode(backward: $0) ?? false }
    }

    private func capsuleMoved(to frame: NSRect?) {
        guard let frame, isOn else {
            session = nil
            activeMode = nil
            lastTranscription = nil
            frontApp?.cancel()
            frontApp = nil
            caption?.close()
            caption = nil
            return
        }
        let bundleID = frontmostBundleID()
        session = (bundleID, frame)
        activeMode = voice.modes.mode(for: bundleID)
        let level = voice.appContext
        let app = level == .off ? nil : dictatedApp()
        frontApp = app.map { app in Task { await VoiceAppContextReader.read(level, of: app) } }
        showCaption()
    }

    /// Tab while listening: this recording's next mode, remembered for an app with a bundle id.
    private func switchMode(backward: Bool) -> Bool {
        guard isOn, let session, capsule?.state.phase == .listening else { return false }
        let next = voice.modes.next(after: activeMode?.id, backward: backward)
        activeMode = next
        if let bundleID = session.bundleID { voice.modes.assign(next?.id, to: bundleID) }
        showCaption()
        return true
    }

    private func showCaption() {
        guard let session, let activeMode else {
            caption?.close()
            caption = nil
            return
        }
        let caption = caption ?? VoiceModeCaption()
        self.caption = caption
        caption.show(activeMode.name, above: session.frame)
    }

    // MARK: - Transcription

    func transcribe(_ samples: [Float]) async throws -> String {
        lastTranscription = nil
        guard let route else { throw VoiceAIFailure.noDictationModel }
        let mode = activeMode
        let reading = frontApp
        let transcription = try await run(samples, on: route, mode: mode) { await Self.ready(reading) }
        lastTranscription = transcription
        return transcription.text
    }

    /// A kept recording again, as a dictation would send it now, with the app by name alone.
    func retranscribe(
        _ samples: [Float], on selection: AIModelSelection, mode: VoiceMode?, appName: String?
    ) async throws -> Transcription {
        let named = appName.flatMap { VoiceAppContext(appName: $0, windowTitle: nil) }
        let context = voice.appContext == .off ? nil : named
        return try await run(samples, on: selection, mode: mode) { context }
    }

    private func run(
        _ samples: [Float], on route: AIModelSelection, mode: VoiceMode?,
        context: () async -> VoiceAppContext?
    ) async throws -> Transcription {
        let selection = VoiceRoutePolicy.dictation(route, connections: aiSettings.connections)
        let provider = try VoiceAIRoute.provider(for: selection, settings: aiSettings)
        guard let wav = await VoiceMediaEncoder.wav(samples) else { throw VoiceAIFailure.noSpeech }
        var context = await context()
        try Task.checkCancellation()
        if !VoiceRoutePolicy.seesScreenshot(selection, connections: aiSettings.connections) {
            context?.screenshot = nil
        }
        let audio = AIAudio(data: wav, format: "wav")
        let options = VoicePrompt.DictationOptions(
            cleanup: voice.cleanup, languages: voice.languages, vocabulary: voice.vocabulary,
            context: context)
        let plain = VoicePrompt.dictationRequest(audio: audio, options: options)
        let model = selection.model
        guard let mode else {
            let text = try await collect(plain, as: selection, on: provider)
            return Transcription(text: text, transcript: nil, mode: nil, model: model)
        }
        if !VoiceRoutePolicy.rewritesWhileTranscribing(model) {
            let transcript = try await collect(plain, as: selection, on: provider)
            let rewritten = try await collect(
                VoicePrompt.rewriteRequest(transcript: transcript, mode: mode), as: selection, on: provider)
            return Transcription(text: rewritten, transcript: transcript, mode: mode.name, model: model)
        }
        let rewritten = try await collect(
            VoicePrompt.modeRequest(audio: audio, mode: mode, options: options), as: selection, on: provider)
        return Transcription(text: rewritten, transcript: nil, mode: mode.name, model: model)
    }

    // MARK: - Retry

    /// Retry with…'s rows, by connection and model; the saved routes come first on theirs.
    var retryRoutes: [(title: String, selection: AIModelSelection)] {
        VoiceRoutePolicy.retryChoices(
            aiSettings.connections, saved: [voice.dictationModel, voice.askModel], isEnabled: isRouteEnabled
        ).compactMap { selection in
            guard case .api(let id, let model, _) = selection, let connection = aiSettings.connection(id: id)
            else { return nil }
            return (connection.title + " · " + model, selection)
        }
    }

    /// The connection Cloud transcription was consented to needs no question; any other is asked.
    func confirmRetry(on selection: AIModelSelection) async -> Bool {
        guard !voice.cloudDictation || selection.source != route?.source else { return true }
        guard case .api(let id, let model, _) = selection, let connection = aiSettings.connection(id: id)
        else { return false }
        return await confirm(
            String(localized: "Send This Recording to \(connection.title)?"),
            String(
                localized: """
                    This one recording goes to \(connection.title) to be transcribed by \(model). \
                    Cloud transcription keeps its own model, and your provider's data policy applies.
                    """))
    }

    /// The capture if it ends within `contextGrace`; one still running is left behind, not awaited.
    private static func ready(_ reading: Task<VoiceAppContext?, Never>?) async -> VoiceAppContext? {
        guard let reading else { return nil }
        let (stream, continuation) = AsyncStream<VoiceAppContext?>.makeStream()
        let read = Task { continuation.yield(await reading.value) }
        let timer = Task {
            try? await Task.sleep(for: contextGrace)
            continuation.yield(nil)
        }
        defer {
            read.cancel()
            timer.cancel()
            continuation.finish()
        }
        for await context in stream { return context }
        return nil
    }

    /// The streamed text from its tag; the sentinel or nothing at all is no speech.
    private func collect(
        _ request: AIRequest, as selection: AIModelSelection, on provider: any AIProvider
    ) async throws -> String {
        let fitted = VoiceRoutePolicy.fitted(request, for: selection, connections: aiSettings.connections)
        var text = ""
        for try await event in provider.stream(fitted) {
            if case .text(let delta) = event { text += delta }
        }
        try Task.checkCancellation()
        guard let transcript = VoiceTranscript.dictation(text) else { throw VoiceAIFailure.noSpeech }
        return transcript
    }

    private func isRouteEnabled(_ id: UUID) -> Bool { aiSettings.isRouteEnabled(.api(id)) }
}
