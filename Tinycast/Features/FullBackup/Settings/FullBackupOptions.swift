import SwiftUI

/// The fork's sections as checkboxes, beside upstream's categories; counts show once a file is open.
struct FullBackupSectionSelection: View {
    @Binding var selection: Set<FullBackupSection>
    var available: [FullBackupSection: Int]?

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.Spacing.md, alignment: .leading), count: 2)

    private var offered: [FullBackupSection] {
        guard let available else { return FullBackupSection.allCases }
        return FullBackupSection.allCases.filter { available[$0] != nil }
    }

    private func included(_ section: FullBackupSection) -> Binding<Bool> {
        Binding(
            get: { selection.contains(section) },
            set: { isOn in
                if isOn { selection.insert(section) } else { selection.remove(section) }
            })
    }

    var body: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(offered) { section in
                Toggle(isOn: included(section)) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: section.descriptor.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(section.descriptor.label).lineLimit(1)
                        if let count = available?[section], count > 0 {
                            Text(count, format: .number).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Export half: the sections, and the opt-in that seals keys and tokens with a passphrase.
struct FullBackupExportOptions: View {
    @Bindable var draft: FullBackupDraft

    var body: some View {
        FullBackupSectionSelection(selection: $draft.exportSections)
        Toggle(isOn: $draft.includesSecrets) {
            SettingsRowTitle(.backupExport, "Include API keys and tokens")
            Text("Sealed with a passphrase you choose; without it they can't be read.")
        }
        if draft.includesSecrets {
            LabeledContent {
                VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
                    passphraseField(String(localized: "Passphrase"), $draft.passphrase)
                    passphraseField(String(localized: "Repeat passphrase"), $draft.passphraseAgain)
                }
            } label: {
                Text("Passphrase")
                if let problem = draft.exportProblem {
                    Text(problem).foregroundStyle(.orange)
                }
            }
        }
    }

    private func passphraseField(_ title: String, _ text: Binding<String>) -> some View {
        RevealableSecureField(title: title, text: text, prompt: Text(title))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
            .frame(width: 200)
    }
}

/// Import half: what the file holds, Merge or Replace where it means something, and its keys.
struct FullBackupImportOptions: View {
    @Bindable var draft: FullBackupDraft

    private var replaceable: [FullBackupSection] {
        FullBackupSection.ordered(draft.importSections).filter(\.descriptor.replaces)
    }

    var body: some View {
        if !draft.preview.available.isEmpty {
            FullBackupSectionSelection(selection: $draft.importSections, available: draft.preview.available)
        }
        ForEach(replaceable) { section in
            Picker(selection: modeBinding(section)) {
                ForEach(FullBackupImportMode.allCases) { mode in Text(mode.title).tag(mode) }
            } label: {
                Text(section.descriptor.label)
                Text(
                    draft.mode(for: section) == .merge
                        ? "Adds what's new and updates what matches."
                        : "Also removes what the file doesn't have."
                )
            }
            .pickerStyle(.menu)
        }
        if let secrets = draft.preview.secrets {
            Toggle(isOn: $draft.importsSecrets) {
                Text("API keys and tokens")
                Text("Sealed items: \(secrets.count). Restored only for what this Mac has.")
            }
            if draft.importsSecrets {
                LabeledContent {
                    RevealableSecureField(
                        title: String(localized: "Passphrase"), text: $draft.importPassphrase,
                        prompt: Text("Backup passphrase")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 200)
                } label: {
                    Text("Passphrase")
                }
            }
        }
        if !draft.preview.skipped.isEmpty {
            let skipped = draft.preview.skipped.formatted(.list(type: .and))
            Label(
                "Made by a newer version; these sections will be skipped: \(skipped)",
                systemImage: "info.circle"
            )
            .foregroundStyle(.secondary)
        }
    }

    private func modeBinding(_ section: FullBackupSection) -> Binding<FullBackupImportMode> {
        Binding(get: { draft.mode(for: section) }, set: { draft.modes[section] = $0 })
    }
}

/// Settings › Backup › Automatic Backup: an export on quit, never on a timer.
struct FullBackupAutoExportSection: View {
    @Environment(AppCore.self) private var core

    var body: some View {
        @Bindable var settings = core.fullBackupSettings
        Section {
            Toggle(isOn: $settings.autoExport) {
                SettingsRowTitle(.backupAutomatic, "Export when Tinycast quits")
                Text("Everything but clipboard history, chats and keys, when the last export is old enough.")
            }
            .disabled(settings.folderURL == nil && !settings.autoExport)
            LabeledContent {
                Button("Choose…") {
                    if let folder = FullBackupActions.chooseFolder() { settings.folder = folder }
                }
            } label: {
                SettingsRowTitle(.backupAutomatic, "Backup folder")
                Text(settings.folder ?? String(localized: "None chosen"))
            }
            Picker(selection: $settings.days) {
                ForEach(FullBackupAutoExportPolicy.dayChoices, id: \.self) { days in
                    Text("\(days) days").tag(days)
                }
            } label: {
                SettingsRowTitle(.backupAutomatic, "When the last export is older than")
            }
            .pickerStyle(.menu)
            Picker(selection: $settings.keep) {
                ForEach(FullBackupAutoExportPolicy.keepChoices, id: \.self) { count in
                    Text("\(count) files").tag(count)
                }
            } label: {
                SettingsRowTitle(.backupAutomatic, "Keep")
                if let last = settings.lastExport {
                    Text("Last export: \(last.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .pickerStyle(.menu)
        } header: {
            SettingsSectionHeader(.backupAutomatic)
        }
    }
}
