import SwiftUI

/// Live Voice settings inside the AI pane: consent toggle, provider/model, voice, agent and screen.
struct LiveVoiceSettingsSection: View {
    @Environment(LiveVoiceCoordinator.self) private var coordinator
    @Environment(LiveVoiceSettings.self) private var liveVoice
    @Environment(AISettingsStore.self) private var aiSettings

    @State private var modelDraft = ""
    @State private var locatorModelDraft = ""

    var body: some View {
        @Bindable var liveVoice = liveVoice
        let available = coordinator.proposal != nil
        return Section {
            Toggle(isOn: enabledBinding) {
                SettingsRowTitle(.aiLiveVoice, "Enable Live Voice")
                Text(
                    """
                    Have a real-time spoken conversation over OpenAI Realtime or Gemini Live, with \
                    optional screen sharing and an on-screen pointer.
                    """)
            }
            .disabled(!liveVoice.enabled && !available)
            if !available {
                caption("Add an OpenAI or Google Gemini connection in AI settings first.")
            }
            if liveVoice.enabled {
                liveModelRows
                voicePicker
                if coordinator.activeProviderKind == .openAI {
                    effortPicker
                }
                if !coordinator.availableAgents.isEmpty {
                    agentPicker
                }
                screenModePicker
                locatorRows
                languagePicker
                audioModePicker
            }
        } header: {
            SettingsSectionHeader(.aiLiveVoice)
        } footer: {
            Text(
                """
                Set its shortcut under Commands. Conversations are saved to AI Chat; raw audio is \
                never kept. Screen sharing is confirmed once at the start of each session.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            modelDraft = coordinator.route?.model ?? ""
            locatorModelDraft = coordinator.locatorRoute?.model ?? ""
        }
        .onChange(of: coordinator.route?.model) { _, value in modelDraft = value ?? "" }
        .onChange(of: coordinator.locatorRoute?.model) { _, value in locatorModelDraft = value ?? "" }
    }

    @ViewBuilder
    private var liveModelRows: some View {
        let offered = LiveVoiceRoutePolicy.choices(aiSettings.connections, isEnabled: isRouteEnabled)
        let current = coordinator.route
        Picker(selection: liveConnectionBinding(offered)) {
            if current == nil { Text("None").tag(UUID?.none) }
            ForEach(offered) { connection in
                Text(verbatim: connection.title).tag(Optional(connection.id))
            }
        } label: {
            SettingsRowTitle(.aiLiveVoice, "Connection")
            if current == nil, !offered.isEmpty {
                Text(
                    """
                    The chosen connection was removed or turned off. Nothing is sent until you \
                    choose one.
                    """)
                    .foregroundStyle(Theme.Colors.warningInk)
            }
        }
        LabeledContent {
            TextField("Model", text: $modelDraft)
                .labelsHidden()
                .frame(minWidth: 200)
                .onChange(of: modelDraft) { commitModelDraft() }
        } label: {
            SettingsRowTitle(.aiLiveVoice, "Model")
        }
    }

    private var voicePicker: some View {
        let voices = coordinator.activeProviderKind?.voices ?? []
        return Picker(selection: voiceBinding(voices)) {
            Text("Default").tag(String?.none)
            ForEach(voices, id: \.self) { name in
                Text(verbatim: name.localizedCapitalized).tag(Optional(name))
            }
        } label: {
            SettingsRowTitle(.aiLiveVoice, "Voice")
        }
    }

    private var effortPicker: some View {
        @Bindable var liveVoice = liveVoice
        return Picker(selection: $liveVoice.effort) {
            ForEach(LiveVoiceEffort.allCases) { level in
                Text(effortTitle(level)).tag(level)
            }
        } label: {
            SettingsRowTitle(.aiLiveVoice, "Reasoning effort")
            Text("Minimal answers fastest; higher levels think longer before speaking.")
        }
    }

    private var agentPicker: some View {
        Picker(selection: agentBinding) {
            Text("None").tag(UUID?.none)
            ForEach(coordinator.availableAgents) { agent in
                Label(agent.name, systemImage: agent.symbol).tag(Optional(agent.id))
            }
        } label: {
            SettingsRowTitle(.aiLiveVoice, "Agent")
            Text(
                """
                Uses the agent's instructions and memory, runs longer tasks in the background, \
                and saves conversations to it.
                """)
        }
    }

    @ViewBuilder
    private var screenModePicker: some View {
        @Bindable var liveVoice = liveVoice
        Picker(selection: $liveVoice.screenMode) {
            ForEach(LiveVoiceScreenMode.allCases) { mode in
                Text(screenModeTitle(mode)).tag(mode)
            }
        } label: {
            SettingsRowTitle(.aiLiveVoice, "Screen sharing")
            Text("Always asks once when a session starts.")
        }
        if liveVoice.screenMode != .off, !ScreenRecordingAccess.isGranted {
            HStack(spacing: Theme.Spacing.md) {
                Text("Allow Screen Recording for Redcast in System Settings to share your screen.")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.warningInk)
                Spacer()
                Button("Open System Settings") { ScreenRecordingAccess.openSettings() }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var locatorRows: some View {
        let offered = LiveVoiceRoutePolicy.locatorChoices(
            aiSettings.connections, isEnabled: isRouteEnabled)
        let current = coordinator.locatorRoute
        Picker(selection: locatorConnectionBinding(offered)) {
            Text("Off").tag(UUID?.none)
            ForEach(offered) { connection in
                Text(verbatim: connection.title).tag(Optional(connection.id))
            }
        } label: {
            SettingsRowTitle(.aiLiveVoice, "Screen pointer")
            Text("Highlights buttons and items on screen using a separate vision model.")
        }
        if current != nil {
            LabeledContent {
                TextField("Locator model", text: $locatorModelDraft)
                    .labelsHidden()
                    .frame(minWidth: 200)
                    .onChange(of: locatorModelDraft) { commitLocatorModelDraft() }
            } label: {
                SettingsRowTitle(.aiLiveVoice, "Pointer model")
            }
        }
    }

    private var languagePicker: some View {
        let locale = Locale.current
        let languages = DictationLanguage.allCases.sorted {
            $0.displayName(locale: locale).localizedStandardCompare($1.displayName(locale: locale))
                == .orderedAscending
        }
        return Picker(selection: languageBinding) {
            Text("System language").tag(String?.none)
            Text("Automatic").tag(Optional(LiveVoiceRoutePolicy.autoLanguage))
            Divider()
            ForEach(languages) { language in
                Text(verbatim: language.displayName(locale: locale)).tag(Optional(language.code))
            }
        } label: {
            SettingsRowTitle(.aiLiveVoice, "Language")
        }
    }

    private var audioModePicker: some View {
        @Bindable var liveVoice = liveVoice
        return Picker(selection: $liveVoice.audioMode) {
            ForEach(LiveVoiceAudioMode.allCases) { mode in
                Text(audioModeTitle(mode)).tag(mode)
            }
        } label: {
            SettingsRowTitle(.aiLiveVoice, "Echo handling")
            Text("Automatic cancels speaker audio so you can interrupt; use Headphones for full duplex.")
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { liveVoice.enabled },
            set: { coordinator.setEnabled($0) })
    }

    private var agentBinding: Binding<UUID?> {
        Binding(
            get: { coordinator.agent?.id },
            set: { liveVoice.agent = $0 })
    }

    private var languageBinding: Binding<String?> {
        Binding(
            get: { liveVoice.language },
            set: { liveVoice.language = $0 })
    }

    private func voiceBinding(_ voices: [String]) -> Binding<String?> {
        Binding(
            get: { liveVoice.voice.flatMap { voices.contains($0) ? $0 : nil } },
            set: { liveVoice.voice = $0 })
    }

    private func liveConnectionBinding(_ offered: [AIConnection]) -> Binding<UUID?> {
        Binding(
            get: {
                guard case .api(let id, _, _) = coordinator.route else { return nil }
                return id
            },
            set: { id in
                guard let connection = offered.first(where: { $0.id == id }),
                    let initial = LiveVoiceRoutePolicy.initial(on: connection)
                else { return }
                coordinator.choose(initial)
            })
    }

    private func locatorConnectionBinding(_ offered: [AIConnection]) -> Binding<UUID?> {
        Binding(
            get: {
                guard case .api(let id, _, _) = coordinator.locatorRoute else { return nil }
                return id
            },
            set: { id in
                guard let id else {
                    coordinator.chooseLocator(nil)
                    return
                }
                guard let connection = offered.first(where: { $0.id == id }),
                    let initial = LiveVoiceRoutePolicy.locatorInitial(on: connection)
                else { return }
                coordinator.chooseLocator(initial)
            })
    }

    private func commitModelDraft() {
        let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .api(let id, let current, _) = coordinator.route, !model.isEmpty, model != current
        else { return }
        coordinator.choose(.api(connection: id, model: model, effort: nil))
    }

    private func commitLocatorModelDraft() {
        let model = locatorModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .api(let id, let current, _) = coordinator.locatorRoute, !model.isEmpty,
            model != current
        else { return }
        coordinator.chooseLocator(.api(connection: id, model: model, effort: nil))
    }

    private func isRouteEnabled(_ id: UUID) -> Bool { aiSettings.isRouteEnabled(.api(id)) }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func screenModeTitle(_ mode: LiveVoiceScreenMode) -> LocalizedStringKey {
        switch mode {
        case .everyTurn: "Every turn"
        case .onRequest: "When asked"
        case .off: "Off"
        }
    }

    private func audioModeTitle(_ mode: LiveVoiceAudioMode) -> LocalizedStringKey {
        switch mode {
        case .automatic: "Automatic"
        case .headphones: "Headphones"
        case .mutedWhileSpeaking: "Mute while speaking"
        }
    }

    private func effortTitle(_ effort: LiveVoiceEffort) -> LocalizedStringKey {
        switch effort {
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}
