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
                    field("Instructions") {
                        TextEditor(text: $draft.instructions)
                            .font(.body)
                            .settingsEditorTextArea(height: Theme.Size.editorTextHeight * 1.5)
                    }
                    AIModelSelectionRows(
                        selection: draft.model,
                        inheritedTitle: String(localized: "Same as AI Chat"),
                        select: { draft.model = $0 },
                        modelLabel: { Text("Model") },
                        effortLabel: { Text("Reasoning effort") })
                    Text("Tools run on API connections. On Codex and Claude the agent's context is sent, its tools are not yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    accessField
                    toolsField
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

    private var accessField: some View {
        field("Access") {
            Picker("Access", selection: $draft.access) {
                Text("Read only").tag(AgentAccess.readOnly)
                Text("Change its folder").tag(AgentAccess.workspaceWrite)
                Text("Full access").tag(AgentAccess.fullAccess)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text("Every file change and command asks first, whatever the access.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
