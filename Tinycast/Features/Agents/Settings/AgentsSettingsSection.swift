import SwiftUI

/// The AI pane's list of agents: start a chat with one, edit it, schedule it, or add another.
struct AgentsSettingsSection: View {
    @Environment(AppCore.self) private var core
    @State private var editing: AgentEditRequest?
    @State private var editingSchedule: AgentScheduleEditRequest?

    var body: some View {
        let agents = core.agentCoordinator
        Section {
            ForEach(agents.agents) { agent in
                SettingsRow(title: agent.name, subtitle: agent.directory) {
                    SymbolImage(name: agent.symbol, size: Theme.Size.quickActionHeaderIcon)
                        .frame(width: Theme.Size.settingsRowIcon)
                } trailing: {
                    Button("Schedule…") {
                        editingSchedule = AgentScheduleEditRequest(agent: agent, schedule: nil)
                    }
                    Button("New Chat") { agents.startChat(with: agent) }
                    Button("Edit…") { editing = AgentEditRequest(agent: agent) }
                }
                ForEach(agents.store.schedules(forAgent: agent.id)) { schedule in
                    scheduleRow(schedule, of: agent)
                }
            }
            Button {
                editing = AgentEditRequest(agent: nil)
            } label: {
                SettingsRowTitle(.aiAgents, "Add Agent")
            }
        } header: {
            SettingsSectionHeader(.aiAgents)
        } footer: {
            Text(
                """
                An agent lives in one folder: its chats read that folder's AGENTS.md and skills, and \
                its tools work there. Choose one for a chat from the composer.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .settingsEditorPanel(item: $editing) { request in
            AgentEditorPanel(request: request)
        }
        .settingsEditorPanel(item: $editingSchedule) { request in
            AgentScheduleEditorPanel(request: request)
        }
    }

    private func scheduleRow(_ schedule: AgentSchedule, of agent: AgentProfile) -> some View {
        SettingsRow(title: schedule.name, subtitle: subtitle(of: schedule)) {
            SymbolImage(name: "clock", size: Theme.Size.quickActionHeaderIcon)
                .frame(width: Theme.Size.settingsRowIcon)
        } trailing: {
            Button("Edit…") {
                editingSchedule = AgentScheduleEditRequest(agent: agent, schedule: schedule)
            }
            Toggle("", isOn: enabled(schedule))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Enable \(schedule.name)")
        }
        .padding(.leading, Theme.Spacing.xl)
    }

    /// Read when the pane renders, with no timer: a stale "Next" only waits for the next look.
    private func subtitle(of schedule: AgentSchedule) -> String {
        let summary = AgentSchedulePolicy.summary(of: schedule.rule, calendar: .current, locale: .current)
        if core.agentCoordinator.runs?.isRunning(schedule: schedule.id) == true {
            return summary + " · " + String(localized: "Running…")
        }
        let store = core.agentCoordinator.store
        guard schedule.isEnabled, core.settings.aiEnabled,
            let next = AgentSchedulePolicy.occurrence(
                after: max(store.baseline(for: schedule), Date()), rule: schedule.rule,
                calendar: .current)
        else { return summary }
        let when = next.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return summary + " · " + String(localized: "Next \(when)")
    }

    private func enabled(_ schedule: AgentSchedule) -> Binding<Bool> {
        Binding(
            get: { schedule.isEnabled },
            set: { isOn in
                var updated = schedule
                updated.isEnabled = isOn
                do {
                    try core.agentCoordinator.saveSchedule(updated)
                } catch {
                    core.showMessage(error.localizedDescription, tone: .danger)
                }
            })
    }
}

struct AgentEditRequest: Identifiable {
    let id = UUID()
    let agent: AgentProfile?
}

struct AgentScheduleEditRequest: Identifiable {
    let id = UUID()
    let agent: AgentProfile
    let schedule: AgentSchedule?
}
