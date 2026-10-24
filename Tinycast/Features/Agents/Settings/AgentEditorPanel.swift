import AppKit
import SwiftUI

struct AgentEditorPanel: View {
    @Environment(\.settingsEditorDismiss) private var dismiss
    @Environment(AppCore.self) private var core

    private let existing: AgentProfile?
    @State private var draft: AgentProfile
    @State private var failure: String?
    @State private var showingIconPicker = false
    @State private var found: [AgentSkill] = []
    @State private var scannedSkills = false
    @State private var argumentsText = ""
    @State private var notificationsDenied = false

    private static let iconSymbols = [
        AgentProfile.sfSymbol, "person.crop.circle", "brain", "terminal", "hammer", "wrench.and.screwdriver",
        "doc.text", "book", "graduationcap", "chart.bar", "megaphone", "bubble.left.and.text.bubble.right",
        "globe", "server.rack", "cpu", "camera", "paintbrush", "film", "music.note", "sparkles", "bolt",
        "leaf", "heart", "star"
    ]

    init(request: AgentEditRequest) {
        existing = request.agent
        _draft = State(
            initialValue: request.agent
                ?? AgentProfile(
                    name: "", directory: FileManager.default.homeDirectoryForCurrentUser.path))
        _argumentsText = State(
            initialValue: request.agent?.runtime.map { runtime in
                runtime.arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
            } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsEditorHeader(
                title: existing == nil ? "New Agent" : "Edit \(existing?.name ?? "")",
                subtitle: "Every chat with this agent starts in its folder, with that folder's context.")

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    HStack(alignment: .bottom, spacing: Theme.Spacing.lg) {
                        field("Name") {
                            TextField("Project Assistant", text: $draft.name)
                                .settingsEditorTextField()
                        }
                        iconField
                    }
                    colorField
                    folderField
                    if let existing { shortcutField(for: existing) }
                    runtimeField
                    if draft.runtime != nil { acpModelField }
                    field("Instructions") {
                        TextEditor(text: $draft.instructions)
                            .font(.body)
                            .settingsEditorTextArea(height: Theme.Size.editorTextHeight * 1.5)
                    }
                    if draft.runtime == nil {
                        AIModelSelectionRows(
                            selection: draft.model,
                            inheritedTitle: String(localized: "Same as AI Chat"),
                            select: { draft.model = $0 },
                            modelLabel: { Text("Model") },
                            effortLabel: { Text("Reasoning effort") })
                        Text(
                            """
                            Tools run on API connections. For Codex or Claude with their own tools, \
                            choose them under Runs on.
                            """)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        accessField
                        toolsField
                        permissionsField
                    }
                    if draft.runtime == nil { effortField }
                    backgroundField
                    contextField
                    skillsField
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 560)

            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.destructive)
            }

            HStack(spacing: Theme.Spacing.md) {
                if let existing {
                    Button("Delete", role: .destructive) {
                        dismiss()
                        Task { await core.agentCoordinator.delete(id: existing.id) }
                    }
                    .buttonStyle(.modalAction(.destructive, fillsWidth: false))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.modalAction(.cancel))
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.modalAction(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.dialogInset)
        .frame(width: Theme.Size.editorSheetWidth)
        .settingsEditorPanelSurface()
        .task(id: SkillScan(directory: draft.directory, sources: draft.skillSources)) { await scanSkills() }
    }

    private func field(
        _ title: LocalizedStringKey, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title).font(.callout.weight(.medium))
            content()
        }
    }

    private var iconField: some View {
        field("Icon") {
            Button {
                showingIconPicker = true
            } label: {
                GlyphTile(symbol: draft.symbol, hue: draft.hue, size: Theme.Size.settingsRowIcon)
                    .frame(width: 40)
            }
            .accessibilityLabel("Icon")
            .popover(isPresented: $showingIconPicker, arrowEdge: .bottom) {
                SymbolPicker(
                    selection: $draft.iconSymbol, fallback: AgentProfile.sfSymbol,
                    symbols: Self.iconSymbols
                ) {
                    showingIconPicker = false
                }
            }
        }
    }

    /// Raycast's seven, the agent's tile wherever it shows; the derived one is ticked until picked.
    private var colorField: some View {
        field("Color") {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(RaycastHue.agentChoices) { hue in
                    let isOn = draft.hue == hue
                    Button {
                        draft.color = hue.rawValue
                    } label: {
                        Circle()
                            .fill(hue.tileColor)
                            .frame(width: Theme.Size.settingsRowIcon, height: Theme.Size.settingsRowIcon)
                            .overlay {
                                if isOn {
                                    Image(systemName: "checkmark")
                                        .font(Theme.Typography.disclosure)
                                        .foregroundStyle(Color.white)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(hue.title)
                    .accessibilityLabel(hue.title)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }

    private var folderField: some View {
        field("Folder") {
            HStack(spacing: Theme.Spacing.md) {
                TextField("~/dev/projects/my-project", text: $draft.directory)
                    .settingsEditorTextField()
                Button("Choose…", action: chooseFolder)
            }
        }
    }

    /// Recorded at once, like every shortcut recorder, so Cancel leaves a new chord in place.
    private func shortcutField(for agent: AgentProfile) -> some View {
        let handle = core.agentCoordinator.handle(of: agent.id) ?? ""
        return field("Shortcut") {
            ShortcutRecorder(action: .agent(id: agent.id))
            Text("Opens the launcher with @\(handle) typed, ready for a task or a chat.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var runtimeField: some View {
        field("Runs on") {
            Picker("Runs on", selection: runtimeKind) {
                Text("Tinycast, on the chat's model").tag(AgentRuntime.Kind?.none)
                Divider()
                ForEach(AgentRuntime.Kind.allCases) { kind in
                    Text(kind.title).tag(AgentRuntime.Kind?.some(kind))
                }
            }
            .labelsHidden()
            if draft.runtime != nil {
                HStack(spacing: Theme.Spacing.md) {
                    TextField("Command", text: runtimeCommand)
                        .settingsEditorTextField()
                        .frame(width: 140)
                    TextField("Arguments", text: $argumentsText)
                        .settingsEditorTextField()
                        .onChange(of: argumentsText) {
                            draft.runtime?.arguments = AgentRuntime.arguments(parsing: argumentsText)
                        }
                }
                Text(
                    """
                    It runs over the Agent Client Protocol with its own login, model and tools, \
                    in the agent's folder, and asks here before each action. Claude Code and Codex \
                    adapters download through npx on first use.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var runtimeKind: Binding<AgentRuntime.Kind?> {
        Binding(
            get: { draft.runtime?.kind },
            set: { kind in
                if kind != draft.runtime?.kind { draft.acpChoices = ACPChoices() }
                draft.runtime = kind.map(AgentRuntime.preset)
                argumentsText = draft.runtime?.arguments.joined(separator: " ") ?? ""
            })
    }

    /// The list this agent's last session offered, while it still runs the same program.
    @ViewBuilder
    private var acpModelField: some View {
        let offered =
            existing?.runtime == draft.runtime
            ? existing.flatMap { core.agentCoordinator.offeredModels(of: $0.id) } : nil
        field("Model") {
            if let offered {
                Picker("Model", selection: $draft.acpModel) {
                    Text("The agent's default").tag(String?.none)
                    Divider()
                    if let kept = draft.acpModel, !offered.offers(kept) {
                        Text(verbatim: kept).tag(String?.some(kept))
                    }
                    ForEach(offered.choices) { choice in
                        Text(verbatim: choice.name).tag(String?.some(choice.value))
                    }
                }
                .labelsHidden()
                Text("Each new session starts on it, and a model picked in a chat changes it here too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("The agent's default", text: acpModelText)
                    .settingsEditorTextField()
                Text(
                    """
                    The agent's own name for the model, such as sonnet. Its list shows here once a chat \
                    with the agent has started.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var acpModelText: Binding<String> {
        Binding(
            get: { draft.acpModel ?? "" },
            set: { draft.acpModel = $0.isEmpty ? nil : $0 })
    }

    private var runtimeCommand: Binding<String> {
        Binding(
            get: { draft.runtime?.command ?? "" },
            set: { draft.runtime?.command = $0 })
    }

    private var accessField: some View {
        field("Access") {
            SteadySegmentedPicker(
                title: String(localized: "Access"),
                options: [
                    .init(value: .readOnly, title: String(localized: "Read only")),
                    .init(value: .workspaceWrite, title: String(localized: "Change its folder")),
                    .init(value: .fullAccess, title: String(localized: "Full access"))
                ],
                selection: $draft.access)
        }
    }

    private var toolsField: some View {
        field("Tools") {
            HStack(spacing: Theme.Spacing.lg) {
                Toggle("Files", isOn: tool(.files))
                Toggle("Terminal", isOn: tool(.terminal)).disabled(!draft.access.writes)
                Toggle("Web", isOn: tool(.web))
                Toggle("Memory", isOn: tool(.memory))
            }
            .toggleStyle(.checkbox)
            HStack(spacing: Theme.Spacing.lg) {
                Toggle("Notes", isOn: tool(.notes)).disabled(!core.settings.notesEnabled)
                Toggle("Screen", isOn: tool(.screen)).disabled(!core.settings.screenAwarenessEnabled)
                Toggle("Sub-agents", isOn: tool(.delegate))
            }
            .toggleStyle(.checkbox)
            Text("Web reads pages and searches with the engines in Settings → AI → Chat.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                """
                Notes searches and reads your Tinycast Notes, and always asks before adding to \
                them. Notes must be on.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(
                """
                Screen reads the text of the window behind Tinycast, never a picture, and always \
                asks first, naming the app. Screen Awareness must be on.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(
                """
                Sub-agents hands a read-only task to a copy of the agent on the same model; its cost \
                counts toward the reply.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// One row per risk the agent can reach today; a risk it cannot reach keeps its rule unseen.
    @ViewBuilder
    private var permissionsField: some View {
        let writes = draft.access.writes
        let risks: [(LocalizedStringKey, AgentToolRisk)] =
            (writes && draft.tools.contains(.files) ? [("Changes", .change)] : [])
            + (writes && draft.tools.contains(.terminal) ? [("Commands", .execute)] : [])
            + (draft.tools.contains(.web) ? [("Web", .network)] : [])
        if !risks.isEmpty {
            field("Permissions") {
                Grid(
                    alignment: .leading, horizontalSpacing: Theme.Spacing.md,
                    verticalSpacing: Theme.Spacing.sm
                ) {
                    ForEach(risks, id: \.1) { title, risk in
                        GridRow {
                            Text(title)
                            Picker(title, selection: rule(risk)) {
                                ForEach(AgentConsentRule.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
                Text("Always Allow also applies to runs nobody is watching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A run nobody watches: what its requests get, whether it says it ended, and its time limit.
    private var backgroundField: some View {
        field("In the background") {
            SteadySegmentedPicker(
                title: String(localized: "In the background"),
                options: [
                    .init(value: .ask, title: String(localized: "Ask me")),
                    .init(value: .decline, title: String(localized: "Decline"))
                ],
                selection: background.consent)
            Text(
                """
                Ask me shows the dialog only while you're at the Mac, with Don't Allow on Return. \
                Otherwise the request is declined and the agent is told.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Toggle("Notify in Notification Center when a run ends", isOn: notifies)
                .toggleStyle(.checkbox)
            if notificationsDenied {
                Text("Notifications are off for Tinycast. Turn them on in System Settings › Notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Notification Settings") {
                    guard
                        let url = URL(
                            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                    else { return }
                    NSWorkspace.shared.open(url)
                }
            }
            // Tinycast's loop takes its time from Effort; an agent on its own CLI keeps its own limit.
            if draft.runtime != nil {
                Stepper(value: background.minutes, in: AgentBackgroundPolicy.minuteRange, step: 5) {
                    Text("Stop a run after \(draft.backgroundPolicy.minutes) minutes")
                }
            }
        }
    }

    /// How much a run may do: its rounds, tool output, sub-agents and time in the background.
    private var effortField: some View {
        field("Effort") {
            SteadySegmentedPicker(
                title: String(localized: "Effort"),
                options: AgentEffort.allCases.map { .init(value: $0, title: $0.title) },
                selection: effort)
            Text(draft.effortLevel.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The effort an untouched agent reads is stored as nothing, so its file says nothing about it.
    private var effort: Binding<AgentEffort> {
        Binding(
            get: { draft.effortLevel },
            set: { draft.effort = $0 == AgentEffort.lasting(draft.backgroundPolicy.minutes) ? nil : $0 })
    }

    /// The defaults are stored as nothing, so an untouched agent's file says nothing about them.
    private var background: Binding<AgentBackgroundPolicy> {
        Binding(
            get: { draft.backgroundPolicy },
            set: { draft.background = $0 == AgentBackgroundPolicy() ? nil : $0 })
    }

    /// macOS asks once, on this click; a refusal turns the switch back off and says where it lives.
    private var notifies: Binding<Bool> {
        Binding(
            get: { draft.backgroundPolicy.notifies },
            set: { isOn in
                background.wrappedValue.notifies = isOn
                notificationsDenied = false
                guard isOn else { return }
                Task {
                    guard await !AgentRunNotifier.authorize() else { return }
                    background.wrappedValue.notifies = false
                    notificationsDenied = true
                }
            })
    }

    private var contextField: some View {
        field("Context") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Toggle("The folder's AGENTS.md", isOn: $draft.readsProjectInstructions)
                Toggle("Global ~/.agents/AGENTS.md", isOn: $draft.readsGlobalInstructions)
                Toggle("Project skills in .agents/skills", isOn: source(.project))
                Toggle("Global skills in ~/.agents, ~/.config/agents and ~/.claude", isOn: source(.global))
            }
            .toggleStyle(.checkbox)
        }
    }

    /// One row per name, the folder that won beside it; the mode says what a new skill does.
    @ViewBuilder
    private var skillsField: some View {
        if !draft.skillSources.isEmpty {
            field("Skills") {
                SteadySegmentedPicker(
                    title: String(localized: "Skills"),
                    options: [
                        .init(value: .all, title: String(localized: "All skills")),
                        .init(value: .selected, title: String(localized: "Only selected"))
                    ],
                    selection: skillMode)
                if skillMode.wrappedValue == .all {
                    Text("Every skill found is offered except those switched off; one added later is in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Only the skills switched on are offered; one added later stays out until picked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if scannedSkills, found.isEmpty {
                    Text("No skills in these folders yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(found, id: \.directory) { skill in
                        Toggle(isOn: skillBinding(skill.name)) {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: Theme.Spacing.sm) {
                                    Text(verbatim: skill.name)
                                    Text(verbatim: (skill.root as NSString).abbreviatingWithTildeInPath)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Text(verbatim: skill.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .help(skill.manifestPath)
                    }
                }
            }
        }
    }

    private func tool(_ kind: AgentToolKind) -> Binding<Bool> {
        Binding(
            get: { draft.tools.contains(kind) },
            set: { on in
                if on { draft.tools.insert(kind) } else { draft.tools.remove(kind) }
            })
    }

    private func rule(_ risk: AgentToolRisk) -> Binding<AgentConsentRule> {
        Binding(
            get: { AgentConsentPolicy.rule(for: risk, of: draft) },
            set: { draft.consent = AgentConsentRules.setting($0, for: risk, in: draft.consent) })
    }

    private func source(_ source: AgentSkillSource) -> Binding<Bool> {
        Binding(
            get: { draft.skillSources.contains(source) },
            set: { on in
                if on { draft.skillSources.insert(source) } else { draft.skillSources.remove(source) }
            })
    }

    /// Only Selected starts from what All had on, so switching modes changes nothing by itself.
    private var skillMode: Binding<AgentSkillSelection.Mode> {
        Binding(
            get: { draft.skillSelection?.mode ?? .all },
            set: { mode in
                var selection = draft.skillSelection ?? AgentSkillSelection()
                if mode == .selected, selection.names.isEmpty {
                    selection.names = Set(found.map(\.name)).subtracting(draft.disabledSkills)
                }
                selection.mode = mode
                draft.skillSelection = selection == AgentSkillSelection() ? nil : selection
            })
    }

    /// All switches a name off by leaving it out; Only Selected switches it on by naming it.
    private func skillBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: {
                AgentSkillSelection.offers(
                    name, in: draft.skillSelection, disabled: draft.disabledSkills)
            },
            set: { on in
                if var selection = draft.skillSelection, selection.mode == .selected {
                    if on { selection.names.insert(name) } else { selection.names.remove(name) }
                    draft.skillSelection = selection
                } else if on {
                    draft.disabledSkills.remove(name)
                } else {
                    draft.disabledSkills.insert(name)
                }
            })
    }

    /// Only while the editor is open: the folders are read on open and when a source changes.
    private func scanSkills() async {
        let directory = AgentPathPolicy.resolve(
            draft.directory, in: AgentContextLoader.home, home: AgentContextLoader.home)
        let sources = draft.skillSources
        found = await Task.detached(priority: .userInitiated) {
            AgentContextLoader.skills(in: directory, sources: sources)
        }.value
        scannedSkills = true
    }

    private struct SkillScan: Equatable {
        let directory: String
        let sources: Set<AgentSkillSource>
    }

    /// An accessory app must activate first, or the panel opens behind the frontmost app.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.directory = url.path
    }

    private func save() {
        var value = draft
        value.acpModel = draft.acpModel?.trimmingCharacters(in: .whitespaces)
        if value.acpModel?.isEmpty == true { value.acpModel = nil }
        value.directory = AgentPathPolicy.resolve(
            draft.directory, in: AgentContextLoader.home, home: AgentContextLoader.home)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: value.directory, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            failure = String(localized: "That folder doesn't exist.")
            return
        }
        do {
            if existing == nil {
                try core.agentCoordinator.add(value)
            } else {
                try core.agentCoordinator.update(value)
            }
            dismiss()
        } catch {
            failure = error.errorDescription
        }
    }
}
