import Foundation

/// The cloud engine behind the Dictation shortcut; capture, panel and insertion stay Dictation's.
@MainActor
final class VoiceCloudTranscriber {
    private let settings: AppSettings
    private let voice: VoiceAISettings
    private let aiSettings: AISettingsStore
    private let confirm: (_ title: String, _ message: String) async -> Bool
    private var enableTask: Task<Void, Never>?

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

    /// nil while no connection can hear audio, which is what keeps the switch disabled.
    var selection: AIModelSelection? {
        VoiceRoutePolicy.resolve(
            voice.dictationModel, use: .dictation, connections: aiSettings.connections,
            isEnabled: { [aiSettings] in aiSettings.isRouteEnabled(.api($0)) })
    }

    /// Turning it on is consent: the dialog names where the audio goes before any is sent.
    func setEnabled(_ enabled: Bool) {
        guard enabled != voice.cloudDictation else { return }
        guard enabled else {
            enableTask?.cancel()
            voice.cloudDictation = false
            return
        }
        guard enableTask == nil, case .api(let id, let model, _) = selection,
            let connection = aiSettings.connection(id: id)
        else { return }
        enableTask = Task { [weak self] in
            guard let self else { return }
            defer { enableTask = nil }
            let approved = await confirm(
                String(localized: "Transcribe Dictation in the Cloud?"),
                String(
                    localized: """
                        Each finished recording goes to \(connection.title) to be transcribed by \
                        \(model). Tinycast keeps no copy of the audio; your provider's data policy \
                        applies.
                        """))
            guard approved, !Task.isCancelled else { return }
            voice.cloudDictation = true
        }
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let selection else { throw VoiceAIFailure.noDictationModel }
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
}
