import AppKit

/// The cloud engine behind the Dictation shortcut; capture, panel and insertion stay Dictation's.
@MainActor
final class VoiceCloudTranscriber {
    private let settings: AppSettings
    private let voice: VoiceAISettings
    private let aiSettings: AISettingsStore
    private let confirm: (_ title: String, _ message: String) async -> Bool
    private let frontmostBundleID: @MainActor () -> String?
    private var consentTask: Task<Void, Never>?
    private weak var capsule: DictationPanelController?
    /// While the capsule is up: the app it opened over, its frame, and the mode it names.
    private var session: (bundleID: String?, frame: NSRect)?
    private(set) var activeMode: VoiceMode?
    private var caption: VoiceModeCaption?

    init(
        settings: AppSettings, voice: VoiceAISettings, aiSettings: AISettingsStore,
        confirm: @escaping (_ title: String, _ message: String) async -> Bool,
        frontmostBundleID: @escaping @MainActor () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    ) {
        self.settings = settings
        self.voice = voice
        self.aiSettings = aiSettings
        self.confirm = confirm
        self.frontmostBundleID = frontmostBundleID
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
        consentTask = Task { [weak self] in
            guard let self else { return }
            defer { consentTask = nil }
            let approved = await confirm(
                title,
                String(
                    localized: """
                        Each finished recording goes to \(connection.title) to be transcribed by \
                        \(model). Tinycast keeps no copy of the audio; your provider's data policy \
                        applies.
                        """))
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
            caption?.close()
            caption = nil
            return
        }
        let bundleID = frontmostBundleID()
        session = (bundleID, frame)
        activeMode = voice.modes.mode(for: bundleID)
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

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let selection = route else { throw VoiceAIFailure.noDictationModel }
        let provider = try VoiceAIRoute.provider(for: selection, settings: aiSettings)
        let mode = activeMode
        guard let wav = await VoiceMediaEncoder.wav(samples) else { throw VoiceAIFailure.noSpeech }
        try Task.checkCancellation()
        let audio = AIAudio(data: wav, format: "wav")
        let options = VoicePrompt.DictationOptions(
            cleanup: voice.cleanup, language: language, vocabulary: voice.vocabulary)
        let plain = VoicePrompt.dictationRequest(audio: audio, options: options)
        guard let mode else { return try await collect(plain, on: provider) }
        if case .api(_, let model, _) = selection, !VoiceRoutePolicy.rewritesWhileTranscribing(model) {
            let transcript = try await collect(plain, on: provider)
            return try await collect(VoicePrompt.rewriteRequest(transcript: transcript, mode: mode), on: provider)
        }
        return try await collect(VoicePrompt.modeRequest(audio: audio, mode: mode, options: options), on: provider)
    }

    /// The streamed text, cleaned; the sentinel or nothing at all is no speech.
    private func collect(_ request: AIRequest, on provider: any AIProvider) async throws -> String {
        var text = ""
        for try await event in provider.stream(request) {
            if case .text(let delta) = event { text += delta }
        }
        try Task.checkCancellation()
        guard let transcript = VoiceTranscript.cleaned(text) else { throw VoiceAIFailure.noSpeech }
        return transcript
    }

    private func isRouteEnabled(_ id: UUID) -> Bool { aiSettings.isRouteEnabled(.api(id)) }
}
