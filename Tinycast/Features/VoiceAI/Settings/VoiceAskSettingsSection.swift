import SwiftUI

/// A section of the AI pane: Ask by Voice reads the window through Screen Awareness.
struct VoiceAskSettingsSection: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var voice = core.voiceSettings
        let coordinator = core.voiceAskCoordinator
        let available = coordinator.proposal != nil
        return Section {
            Toggle(isOn: enabledBinding) {
                SettingsRowTitle(.aiAskByVoice, "Enable Ask by Voice")
                Text(
                    """
                    Speak a question about the window in front of you. The answer opens beside it, or \
                    goes into the field you asked about.
                    """)
            }
            .disabled(!voice.askEnabled && (!settings.screenAwarenessEnabled || !available))
            if !settings.screenAwarenessEnabled {
                caption("Turn on Screen Awareness first.")
            } else if !available {
                caption("Add an OpenRouter or OpenAI-compatible connection in AI settings first.")
            }
            Picker(selection: $voice.askMode) {
                ForEach(DictationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                SettingsRowTitle(.aiAskByVoice, "Shortcut behavior")
            }
            .disabled(!voice.askEnabled)
            if voice.askEnabled, let issue = coordinator.holdShortcutIssue {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if voice.askEnabled {
                VoiceModelRow(use: .ask, selection: voice.askModel, choose: coordinator.choose)
                if !core.agentCoordinator.agents.isEmpty {
                    agentPicker
                }
            }
        } header: {
            SettingsSectionHeader(.aiAskByVoice)
        } footer: {
            Text(
                """
                Set their shortcuts under Commands. Edit Selection by Voice rewrites the text you \
                selected as you say. A recording is never saved. Dictation History keeps the text of \
                a question and its answer, and of an edit; what was read is kept only if you continue \
                in AI Chat, or as the chat of an agent's run.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var agentPicker: some View {
        Picker(selection: agentBinding) {
            Text("The model above").tag(UUID?.none)
            ForEach(core.agentCoordinator.agents) { agent in
                Label(agent.name, systemImage: agent.symbol).tag(Optional(agent.id))
            }
        } label: {
            SettingsRowTitle(.aiAskByVoice, "Answer with")
            Text(
                """
                With an agent, the model above only writes down your request, and the agent works on \
                it in the background with the window in front attached. Each run is saved as a chat \
                with the agent, including the window's text and any screenshot.
                """)
        }
    }

    /// A deleted agent reads as the model, which is what answers now.
    private var agentBinding: Binding<UUID?> {
        Binding(
            get: { core.voiceAskCoordinator.agent?.id },
            set: { core.voiceSettings.askAgent = $0 })
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { core.voiceSettings.askEnabled },
            set: { core.voiceAskCoordinator.setEnabled($0) })
    }
}
