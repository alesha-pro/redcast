import SwiftUI

/// The AI pane's Agent Sessions section; opening it is the gesture that reads the hook files.
struct AgentSessionsSettingsSection: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var appSettings
    @State private var terminals: [AgentTerminal] = []
    @State private var summary: AgentSessionsCoordinator.LiveStatusSummary?
    @State private var plan: AgentSessionsCoordinator.LiveStatusPlan?

    private var coordinator: AgentSessionsCoordinator { core.agentSessionsCoordinator }
    private var isOn: Bool { summary?.isOn ?? false }

    var body: some View {
        Section {
            Toggle(isOn: enabledBinding) {
                SettingsRowTitle(.aiAgentSessions, "Search agent sessions")
                Text(
                    """
                    Find Claude Code, Codex, Gemini CLI, OpenCode and Tinycast chats from the launcher and \
                    resume them in their folder. Nothing is read until you open Search Agent Sessions, and \
                    nothing leaves this Mac.
                    """)
            }
            Picker(selection: terminalBinding) {
                Text("Automatic").tag("")
                ForEach(terminals, id: \.self) { terminal in
                    Text(verbatim: terminal.displayName).tag(terminal.rawValue)
                }
            } label: {
                SettingsRowTitle(.aiAgentSessions, "Resume in")
            }
            .disabled(!appSettings.agentSessionsEnabled)
            LabeledContent {
                AgentFolderField(placeholder: "~/.claude", text: folderBinding(\.agentSessionsClaudeFolder))
            } label: {
                SettingsRowTitle(.aiAgentSessions, "Claude Code folder")
                folderNote(appSettings.agentSessionsClaudeFolder, variable: "CLAUDE_CONFIG_DIR", default: "~/.claude")
            }
            .disabled(!appSettings.agentSessionsEnabled)
            LabeledContent {
                AgentFolderField(placeholder: "~/.codex", text: folderBinding(\.agentSessionsCodexFolder))
            } label: {
                SettingsRowTitle(.aiAgentSessions, "Codex folder")
                folderNote(appSettings.agentSessionsCodexFolder, variable: "CODEX_HOME", default: "~/.codex")
            }
            .disabled(!appSettings.agentSessionsEnabled)
            SettingsRow(title: "Live status", subtitle: statusText, anchor: .aiAgentSessions) {
                liveStatusButtons
            }
            .disabled(!appSettings.agentSessionsEnabled)
            Toggle(isOn: menuBarBinding) {
                Text("Show running agents in the menu bar")
            }
            .disabled(!appSettings.agentSessionsEnabled || !isOn)
        } header: {
            SettingsSectionHeader(.aiAgentSessions)
        } footer: {
            Text(
                """
                Live status adds small hooks to Claude Code and Codex that tell Tinycast when an agent \
                finishes or waits for you. You see every change before it is written, and the original \
                file is backed up.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .task(id: coordinator.isActive) {
            guard coordinator.isActive else { return }
            let installed = AgentTerminalRunner.installed()
            terminals = AgentTerminal.allCases.filter { $0.bundleIdentifiers.contains(where: installed.contains) }
            summary = await coordinator.liveStatusSummary()
        }
        .settingsEditorPanel(item: $plan) { plan in
            AgentHooksPanel(plan: plan) {
                Task { summary = await coordinator.liveStatusSummary() }
            }
        }
    }

    @ViewBuilder private var liveStatusButtons: some View {
        if let summary {
            if summary.isInstalledAnywhere {
                if summary.needsUpdate { Button("Update…") { review(on: true) } }
                Button("Turn Off…") { review(on: false) }
            } else {
                Button("Turn On…") { review(on: true) }
            }
        }
    }

    private var statusText: String? {
        guard let summary else { return nil }
        guard summary.isInstalledAnywhere else { return String(localized: "Off") }
        if summary.needsUpdate { return String(localized: "Needs updating") }
        let names = AgentHookTarget.allCases.filter { summary.states[$0] == .installed }
            .map(\.agent.productName)
        return String(localized: "On for \(names.formatted(.list(type: .and)))")
    }

    private func review(on: Bool) {
        Task { plan = await coordinator.prepareLiveStatus(on: on) }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { appSettings.agentSessionsEnabled },
            set: { enabled in
                coordinator.setEnabled(enabled)
                // Switching the hub off leaves hooks that now do nothing; offer to take them out.
                if !enabled, summary?.isInstalledAnywhere == true { review(on: false) }
            })
    }

    private var terminalBinding: Binding<String> {
        Binding(
            get: { appSettings.agentSessionsTerminal },
            set: { appSettings.agentSessionsTerminal = $0 })
    }

    /// Live status is read again, since its hook files live in the folder that moved.
    private func folderBinding(_ key: ReferenceWritableKeyPath<AppSettings, String>) -> Binding<String> {
        Binding(
            get: { appSettings[keyPath: key] },
            set: { text in
                appSettings[keyPath: key] = text.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { summary = await coordinator.liveStatusSummary() }
            })
    }

    /// One `stat` per render of the section, which only Settings shows.
    private func folderNote(_ text: String, variable: String, default folder: String) -> Text {
        let url = AgentSessionsLocations.folder(text, home: FileManager.default.homeDirectoryForCurrentUser)
        guard text.isEmpty || url.map({ AgentSessionsCoordinator.folderExists($0.path) }) == true else {
            return Text("No folder at this path.")
        }
        return Text("Where \(variable) points, if you set it. Empty reads \(folder).")
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { appSettings.agentStatusMenuBar },
            set: { coordinator.setStatusItemEnabled($0) })
    }
}

/// One agent's folder, saved on Return or when the field is left rather than on every keystroke.
private struct AgentFolderField: View {
    let placeholder: String
    @Binding var text: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft, prompt: Text(verbatim: placeholder))
            .labelsHidden()
            .font(.callout.monospaced())
            .autocorrectionDisabled()
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { save() }
            }
            .onAppear { draft = text }
    }

    private func save() {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines) != text else { return }
        text = draft
    }
}
