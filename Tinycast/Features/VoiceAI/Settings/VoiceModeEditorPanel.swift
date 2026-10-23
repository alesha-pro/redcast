import SwiftUI

struct VoiceModeEditRequest: Identifiable {
    let id = UUID()
    let mode: VoiceMode?
}

/// A mode's name and instructions; a built-in keeps its name and can go back to its own wording.
struct VoiceModeEditorPanel: View {
    @Environment(\.settingsEditorDismiss) private var dismiss
    @Environment(AppCore.self) private var core

    private let existing: VoiceMode?
    @State private var name: String
    @State private var instructions: String

    private static let placeholder = String(
        localized: "Write it as a formal email in the language it was spoken in.")

    init(request: VoiceModeEditRequest) {
        existing = request.mode
        _name = State(initialValue: request.mode?.name ?? "")
        _instructions = State(initialValue: request.mode?.instructions ?? "")
    }

    private var builtIn: VoiceMode? { existing.flatMap { VoiceModeCatalog.builtIn($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsEditorHeader(
                title: existing == nil ? "New Mode" : "Edit \(existing?.name ?? "")",
                subtitle: "Your dictation is rewritten with these instructions before it is typed.")
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Name")
                    .font(.callout.weight(.medium))
                TextField("Make Formal", text: nameBinding)
                    .settingsEditorTextField()
                    .disabled(builtIn != nil)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Instructions")
                    .font(.callout.weight(.medium))
                TextEditor(text: $instructions)
                    .font(.body)
                    .settingsEditorTextArea(height: Theme.Size.editorTextHeight)
                    .overlay(alignment: .topLeading) {
                        if instructions.isEmpty {
                            Text(Self.placeholder)
                                .foregroundStyle(.tertiary)
                                .padding(Theme.Spacing.md)
                                .allowsHitTesting(false)
                        }
                    }
                Text("Tinycast always tells the model that what you said is text to rewrite, never a request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            buttons
        }
        .padding(Theme.Spacing.dialogInset)
        .frame(width: Theme.Size.editorSheetWidth)
        .settingsEditorPanelSurface()
    }

    private var buttons: some View {
        HStack(spacing: Theme.Spacing.md) {
            if let existing, builtIn == nil {
                Button("Delete", role: .destructive) {
                    core.voiceSettings.modes.remove(existing.id)
                    dismiss()
                }
                .buttonStyle(.modalAction(.destructive, fillsWidth: false))
            } else if let builtIn, instructions != builtIn.instructions {
                Button("Reset to Default") { instructions = builtIn.instructions }
                    .buttonStyle(.modalAction(.cancel, fillsWidth: false))
                    // Its own width first: sharing the row three ways folds its label in two.
                    .fixedSize()
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.modalAction(.cancel))
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(.modalAction(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isComplete)
        }
    }

    private var draft: VoiceMode {
        VoiceMode(
            id: existing?.id ?? UUID(),
            name: builtIn?.name ?? name.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var nameBinding: Binding<String> {
        Binding(get: { name }, set: { name = String($0.prefix(VoiceMode.maxNameLength)) })
    }

    private func save() {
        let mode = draft
        guard mode.isComplete else { return }
        core.voiceSettings.modes.save(mode)
        dismiss()
    }
}
