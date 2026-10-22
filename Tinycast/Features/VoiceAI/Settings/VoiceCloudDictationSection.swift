import SwiftUI

/// The Dictation pane's second engine: the same shortcut, transcribed by an AI connection.
struct VoiceCloudDictationSection: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var voice = core.voiceSettings
        let available = core.voiceCloud.selection != nil
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
                VoiceModelRow(use: .dictation, selection: $voice.dictationModel)
                Toggle(isOn: $voice.cleanup) {
                    SettingsRowTitle(.dictationCloudTranscription, "Clean up speech")
                    Text("Leave out fillers and false starts. Off keeps every word.")
                }
                TextField(
                    text: vocabularyBinding,
                    prompt: Text(verbatim: "Tinycast, OpenRouter, Kubernetes")
                ) {
                    SettingsRowTitle(.dictationCloudTranscription, "Words to spell exactly")
                }
                // Qwen's own picker already shows this setting; one row per pane.
                if !showsModelLanguage {
                    Picker(selection: languageBinding) {
                        Text(LocalizedStringResource("dictation-language-auto", defaultValue: "Auto"))
                            .tag("")
                        Divider()
                        ForEach(DictationLanguage.allCases) { language in
                            Text(language.displayName(locale: .current)).tag(language.rawValue)
                        }
                    } label: {
                        SettingsRowTitle(.dictationCloudTranscription, "Language")
                    }
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

    private var showsModelLanguage: Bool {
        settings.dictationModel.isQwen
            && core.dictationCoordinator.models.isInstalled(settings.dictationModel)
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

    private var languageBinding: Binding<String> {
        Binding(
            get: { settings.dictationLanguage ?? "" },
            set: { settings.dictationLanguage = $0.isEmpty ? nil : $0 })
    }
}
