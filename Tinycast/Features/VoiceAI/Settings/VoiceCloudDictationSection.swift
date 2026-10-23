import SwiftUI

/// The Dictation pane's second engine: the same shortcut, transcribed by an AI connection.
struct VoiceCloudDictationSection: View {
    @Environment(AppCore.self) private var core

    var body: some View {
        let voice = core.voiceSettings
        Group {
            cloudSection(voice: voice, available: core.voiceCloud.proposal != nil)
            if voice.cloudDictation { VoiceModesSection() }
        }
    }

    private func cloudSection(voice: VoiceAISettings, available: Bool) -> some View {
        @Bindable var voice = voice
        return Section {
            Toggle(isOn: enabledBinding) {
                SettingsRowTitle(.dictationCloudTranscription, "Transcribe in the cloud")
                Text("Send each recording to an AI connection instead of the on-device model.")
            }
            .disabled(!available && !voice.cloudDictation)
            if !available {
                Text("Add an OpenRouter or OpenAI-compatible connection in AI settings first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if voice.cloudDictation {
                VoiceModelRow(
                    use: .dictation, selection: voice.dictationModel, choose: core.voiceCloud.choose)
                Toggle(isOn: $voice.cleanup) {
                    SettingsRowTitle(.dictationCloudTranscription, "Clean up speech")
                    Text("Leave out fillers and false starts. Off keeps every word.")
                }
                TextField(
                    text: vocabularyBinding,
                    prompt: Text(verbatim: "Redcast, OpenRouter, Kubernetes")
                ) {
                    SettingsRowTitle(.dictationCloudTranscription, "Words to spell exactly")
                }
                languagesRow(voice.languages)
                Picker(selection: $voice.appContext) {
                    Text("Off").tag(VoiceAppContext.Level.off)
                    Text("Name and title").tag(VoiceAppContext.Level.title)
                    Text("Name, title and screenshot").tag(VoiceAppContext.Level.screenshot)
                } label: {
                    SettingsRowTitle(.dictationCloudTranscription, "Use the app in front")
                    Text("Sent with each recording to help spell names and terms, and never saved.")
                    if voice.appContext == .screenshot, !ScreenRecordingAccess.isGranted {
                        Text("No screenshot: allow Screen Recording for Tinycast in System Settings.")
                            .foregroundStyle(.orange)
                    }
                }
                .onChange(of: voice.appContext) { _, level in
                    guard level == .screenshot, !ScreenRecordingAccess.isGranted else { return }
                    ScreenRecordingAccess.request()
                }
            }
        } header: {
            SettingsSectionHeader(.dictationCloudTranscription)
        } footer: {
            Text(
                """
                Audio leaves this Mac only when you finish a recording, and is never saved. Insert \
                while recording stays off.
                """)
        }
    }

    /// A menu of checkmarks; past the limit, the rest wait until one is unchecked.
    private func languagesRow(_ chosen: [String]) -> some View {
        let names = chosen.compactMap(DictationLanguage.init(rawValue:)).map {
            $0.displayName(locale: .current)
        }
        let full = chosen.count >= VoiceLanguagePolicy.limit
        return LabeledContent {
            Menu {
                ForEach(DictationLanguage.allCases) { language in
                    Toggle(isOn: languageBinding(language.rawValue)) {
                        Text(language.displayName(locale: .current))
                    }
                    .disabled(full && !chosen.contains(language.rawValue))
                }
            } label: {
                if names.isEmpty {
                    Text(LocalizedStringResource("dictation-language-auto", defaultValue: "Auto"))
                } else {
                    Text(verbatim: names.formatted(.list(type: .and, width: .narrow)))
                }
            }
            .fixedSize()
        } label: {
            SettingsRowTitle(.dictationCloudTranscription, "Languages I speak")
            Text("The model expects only these, even mixed in one sentence.")
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { core.voiceSettings.cloudDictation },
            set: { core.voiceCloud.setEnabled($0) })
    }

    private var vocabularyBinding: Binding<String> {
        Binding(
            get: { core.voiceSettings.vocabulary },
            set: { core.voiceSettings.vocabulary = String($0.prefix(VoicePrompt.maxVocabularyLength)) })
    }

    private func languageBinding(_ language: String) -> Binding<Bool> {
        Binding(
            get: { core.voiceSettings.languages.contains(language) },
            set: { _ in
                core.voiceSettings.languages = VoiceLanguagePolicy.toggled(
                    language, in: core.voiceSettings.languages)
            })
    }
}
