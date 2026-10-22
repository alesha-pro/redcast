import Foundation

/// The cloud engine behind the Dictation shortcut; capture, panel and insertion stay Dictation's.
@MainActor
final class VoiceCloudTranscriber {
    private let settings: AppSettings
    private let voice: VoiceAISettings
    private let aiSettings: AISettingsStore
    private let confirm: (_ title: String, _ message: String) async -> Bool
    private var consentTask: Task<Void, Never>?

    init(
        settings: AppSettings, voice: VoiceAISettings, aiSettings: AISettingsStore,
        confirm: @escaping (_ title: String, _ message: String) async -> Bool
    ) {
        self.settings = settings
        self.voice = voice
        self.aiSettings = aiSettings
        self.confirm = confirm
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

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let selection = route else { throw VoiceAIFailure.noDictationModel }
        let provider = try VoiceAIRoute.provider(for: selection, settings: aiSettings)
        guard let wav = await VoiceMediaEncoder.wav(samples) else { throw VoiceAIFailure.noSpeech }
        try Task.checkCancellation()
        let request = VoicePrompt.dictationRequest(
            audio: AIAudio(data: wav, format: "wav"),
            options: .init(cleanup: voice.cleanup, language: language, vocabulary: voice.vocabulary))
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
