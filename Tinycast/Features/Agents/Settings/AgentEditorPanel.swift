import AppKit
import SwiftUI

struct AgentEditorPanel: View {
    @Environment(\.settingsEditorDismiss) private var dismiss
    @Environment(AppCore.self) private var core

    private let existing: AgentProfile?
    @State private var draft: AgentProfile
    @State private var failure: String?
    @State private var showingIconPicker = false
    @State private var found: (project: [AgentSkill], global: [AgentSkill]) = ([], [])
    @State private var argumentsText = ""

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
                    folderField
                    runtimeField
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
        .task(id: draft.directory) { await scanSkills() }
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
                SymbolImage(name: draft.symbol, size: 14).frame(width: 40)
            }
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

    private var folderField: some View {
        field("Folder") {
            HStack(spacing: Theme.Spacing.md) {
                TextField("~/dev/projects/my-project", text: $draft.directory)
                    .settingsEditorTextField()
                Button("Choose…", action: chooseFolder)
            }
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
                draft.runtime = kind.map(AgentRuntime.preset)
                argumentsText = draft.runtime?.arguments.joined(separator: " ") ?? ""
            })
    }

    private var runtimeCommand: Binding<String> {
        Binding(
            get: { draft.runtime?.command ?? "" },
            set: { draft.runtime?.command = $0 })
    }

    private var accessField: some View {
        field("Access") {
            Picker("Access", selection: $draft.access) {
                Text("Read only").tag(AgentAccess.readOnly)
                Text("Change its folder").tag(AgentAccess.workspaceWrite)
                Text("Full access").tag(AgentAccess.fullAccess)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var toolsField: some View {
        field("Tools") {
            HStack(spacing: Theme.Spacing.lg) {
                Toggle("Files", isOn: tool(.files))
                Toggle("Terminal", isOn: tool(.terminal)).disabled(!draft.access.writes)
                Toggle("Web", isOn: tool(.web))
                Toggle("Memory", isOn: tool(.memory))
                Toggle("Notes", isOn: tool(.notes)).disabled(!core.settings.notesEnabled)
            }
            .toggleStyle(.checkbox)
            Text(
                """
                Notes searches and reads your Tinycast Notes, and adds to them under Changes. \
                Notes must be on.
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
            (writes && !draft.tools.isDisjoint(with: [.files, .notes]) ? [("Changes", .change)] : [])
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

    private var contextField: some View {
        field("Context") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Toggle("The folder's AGENTS.md", isOn: $draft.readsProjectInstructions)
                Toggle("Global ~/.agents/AGENTS.md", isOn: $draft.readsGlobalInstructions)
                Toggle("Project skills in .agents/skills", isOn: source(.project))
                Toggle("Global skills in ~/.agents/skills", isOn: source(.global))
            }
            .toggleStyle(.checkbox)
        }
    }

    @ViewBuilder
    private var skillsField: some View {
        let offered =
            (draft.skillSources.contains(.project) ? found.project : [])
            + (draft.skillSources.contains(.global) ? found.global : [])
        if !offered.isEmpty {
            field("Skills") {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(offered, id: \.directory) { skill in
                        Toggle(isOn: skillBinding(skill.name)) {
                            Text(skill.name)
                            Text(skill.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
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

    private func skillBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { !draft.disabledSkills.contains(name) },
            set: { on in
                if on { draft.disabledSkills.remove(name) } else { draft.disabledSkills.insert(name) }
            })
    }

    private func scanSkills() async {
        let directory = AgentPathPolicy.resolve(
            draft.directory, in: AgentContextLoader.home, home: AgentContextLoader.home)
        found = await Task.detached(priority: .userInitiated) {
            AgentContextLoader.skills(in: directory)
        }.value
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
