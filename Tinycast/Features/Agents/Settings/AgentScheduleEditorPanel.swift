import SwiftUI

/// One recurring task for an agent: what it asks, when, and where the answer also goes.
struct AgentScheduleEditorPanel: View {
    @Environment(\.settingsEditorDismiss) private var dismiss
    @Environment(AppCore.self) private var core

    private let existing: AgentSchedule?
    @State private var draft: AgentSchedule
    @State private var appendsToNote: Bool
    @State private var noteTitle: String
    @State private var failure: String?

    /// Times are picked on a fixed day with no clock change, so the minutes read back are as shown.
    private static let referenceDay = Calendar.current.startOfDay(
        for: Date(timeIntervalSinceReferenceDate: 12 * 60 * 60))

    init(request: AgentScheduleEditRequest) {
        existing = request.schedule
        let schedule = request.schedule ?? AgentSchedule(agentID: request.agent.id, name: "", prompt: "")
        _draft = State(initialValue: schedule)
        _appendsToNote = State(initialValue: schedule.noteTitle != nil)
        _noteTitle = State(initialValue: schedule.noteTitle ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsEditorHeader(
                title: existing == nil ? "New Schedule" : "Edit \(existing?.name ?? "")",
                subtitle: "Runs only while Tinycast is open. Each run is saved as a chat with this agent.")

            field("Name") {
                TextField("Morning digest", text: $draft.name)
                    .settingsEditorTextField()
            }
            field("Prompt") {
                TextEditor(text: $draft.prompt)
                    .font(.body)
                    .settingsEditorTextArea(height: Theme.Size.editorTextHeight)
                Text("{date} and {time} are filled in when it runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            repeatField
            field("If a run was missed") {
                Picker("If a run was missed", selection: $draft.catchUp) {
                    Text("Run once when back").tag(AgentScheduleCatchUp.once)
                    Text("Skip it").tag(AgentScheduleCatchUp.skip)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }
            noteField
            Toggle("Enabled", isOn: $draft.isEnabled)
                .toggleStyle(.checkbox)

            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.destructive)
            }

            HStack(spacing: Theme.Spacing.md) {
                if let existing {
                    Button("Delete", role: .destructive) {
                        dismiss()
                        Task { await core.agentCoordinator.removeSchedule(id: existing.id) }
                    }
                    .buttonStyle(.modalAction(.destructive, fillsWidth: false))
                    .fixedSize()
                }
                Button("Run Now") {
                    guard let saved = save() else { return }
                    dismiss()
                    core.agentCoordinator.runNow(saved)
                }
                .buttonStyle(.modalAction(.cancel, fillsWidth: false))
                // Its own width first: the filling buttons would otherwise fold its label in two.
                .fixedSize()
                .disabled(!core.settings.aiEnabled || isIncomplete)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.modalAction(.cancel))
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if save() != nil { dismiss() }
                }
                .buttonStyle(.modalAction(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(isIncomplete)
            }
        }
        .padding(Theme.Spacing.dialogInset)
        .frame(width: Theme.Size.editorSheetWidth)
        .settingsEditorPanelSurface(controlsOnGlass: false)
    }

    private var isIncomplete: Bool {
        draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            || draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One menu and the time on a line, so no language's labels can widen the panel.
    private var repeatField: some View {
        field("Repeat") {
            HStack(spacing: Theme.Spacing.lg) {
                Picker("Repeat", selection: cadence) {
                    Text("Daily").tag(Cadence.daily)
                    Text("Weekdays").tag(Cadence.weekdays)
                    Divider()
                    ForEach(AgentScheduleRule.hourChoices, id: \.self) { hours in
                        Text("Every \(hours) hours").tag(Cadence.everyHours(hours))
                    }
                }
                .labelsHidden()
                .fixedSize()
                DatePicker(
                    draft.rule.kind == .everyHours ? "from" : "at", selection: time,
                    displayedComponents: .hourAndMinute)
                    .fixedSize()
            }
        }
    }

    private enum Cadence: Hashable {
        case daily, weekdays
        case everyHours(Int)
    }

    private var cadence: Binding<Cadence> {
        Binding(
            get: {
                switch draft.rule.kind {
                case .daily: .daily
                case .weekdays: .weekdays
                case .everyHours: .everyHours(draft.rule.hours)
                }
            },
            set: { cadence in
                switch cadence {
                case .daily: draft.rule.kind = .daily
                case .weekdays: draft.rule.kind = .weekdays
                case .everyHours(let hours):
                    draft.rule.kind = .everyHours
                    draft.rule.hours = hours
                }
            })
    }

    private var noteField: some View {
        let notesOn = core.settings.notesEnabled
        return field("Notes") {
            Toggle("Append the answer to a note", isOn: $appendsToNote)
                .toggleStyle(.checkbox)
                .disabled(!notesOn)
            if appendsToNote {
                TextField("Agent Reports", text: $noteTitle)
                    .settingsEditorTextField()
                    .disabled(!notesOn)
            }
            if !notesOn {
                Text("Turn on Notes to use this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var time: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    byAdding: .minute, value: draft.rule.minuteOfDay, to: Self.referenceDay)
                    ?? Self.referenceDay
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.rule.minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }

    private func field(
        _ title: LocalizedStringKey, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title).font(.callout.weight(.medium))
            content()
        }
    }

    /// Nil, with the reason shown, when the store refused it.
    private func save() -> AgentSchedule? {
        var value = draft
        let title = noteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        value.noteTitle = appendsToNote ? (title.isEmpty ? String(localized: "Agent Reports") : title) : nil
        do {
            return try core.agentCoordinator.saveSchedule(value)
        } catch {
            failure = error.errorDescription
            return nil
        }
    }
}
