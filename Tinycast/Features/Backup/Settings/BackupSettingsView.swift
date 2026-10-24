import AppKit
import SwiftUI

struct BackupSettingsView: View {
    @Environment(AppCore.self) private var core
    private var runningApps: RunningAppsMonitor { core.runningApps }
    @State private var raycastFile: URL?
    @State private var passphrase = ""
    @State private var importing = false
    @State private var status: Status?
    @State private var selection: RaycastImportOptions = .all
    @State private var isRaycastExport = false
    @State private var exportSelection = BackupCategory.all
    @State private var importSelection: Set<BackupCategory> = []
    @State private var exporting = false
    @State private var importingBackup = false
    @State private var backupStatus: Status?
    @State private var backupFile: URL?
    @State private var openedManifest: BackupManifest?
    /// Held between opening the file and applying it, so the extracted tree survives the picker.
    @State private var openedStaging: BackupStaging?
    // Fork: the full backup's sections, secrets and import choices.
    @State private var full = FullBackupDraft()

    private enum Status {
        case success(String)
        case failure(String)
    }

    private var raycastRunning: Bool {
        runningApps.runningBundleIDs.contains(where: BackupActions.isRaycastBundleID)
    }

    /// Turning it on may ask first, so the switch follows the setting rather than the click.
    private var settingsFileSync: Binding<Bool> {
        Binding(
            get: { core.settings.settingsFileEnabled },
            set: { enabled in Task { await BackupActions.setSettingsFileEnabled(enabled, core: core) } })
    }

    private var raycastFileSubtitle: String {
        guard let name = raycastFile?.lastPathComponent else {
            return String(localized: "A .rayconfig file from Raycast 2.0 or later.")
        }
        return isRaycastExport
            ? String(localized: "\(name) — Raycast export")
            : String(localized: "\(name) — not a Raycast export")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if exporting {
                        ProgressView().controlSize(.small)
                    } else {
                        // Fork: the full backup's sections count as a selection too.
                        Button("Export…") { runExport() }
                            .disabled(full.blocksExport(upstream: exportSelection.isEmpty))
                    }
                } label: {
                    SettingsRowTitle(.backupExport, "Export Backup")
                    Text("The ticked items, as one .tinycast file.")
                }
                BackupCategorySelection(selection: $exportSelection)
                FullBackupExportOptions(draft: full)  // Fork: full backup
                if let backupStatus { statusRow(backupStatus) }
            } header: {
                SettingsSectionHeader(.backupExport)
            }

            Section {
                LabeledContent {
                    Button("Choose…") { chooseBackupFile() }
                } label: {
                    SettingsRowTitle(.backupImport, "Backup File")
                    Text(backupFileSubtitle)
                }
                if let manifest = openedManifest {
                    BackupCategorySelection(
                        selection: $importSelection, available: available(in: manifest))
                    FullBackupImportOptions(draft: full)  // Fork: full backup
                    LabeledContent {
                        if importingBackup {
                            ProgressView().controlSize(.small)
                        } else {
                            // Fork: the full backup's sections count as a choice too.
                            Button("Import") { runBackupImport() }
                                .disabled(full.blocksImport(upstream: importSelection.isEmpty))
                        }
                    } label: {
                        Text("Import")
                    }
                }
            } header: {
                SettingsSectionHeader(.backupImport)
            }

            Section {
                LabeledContent {
                    Button("Choose…") { chooseRaycastFile() }
                } label: {
                    SettingsRowTitle(.backupImportFromRaycast, "Raycast Export")
                    Text(raycastFileSubtitle)
                }
                LabeledContent {
                    RevealableSecureField(
                        title: String(localized: "Passphrase"), text: $passphrase,
                        prompt: Text("Export password")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    // LabeledContent right-aligns its value text, caret and all; a field reads left.
                    .multilineTextAlignment(.leading)
                    .frame(width: 160)
                    .onSubmit(runRaycastImport)
                } label: {
                    Text("Passphrase")
                }
                RaycastImportSelection(selection: $selection)
                conflictNotice
                LabeledContent {
                    if importing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Import") { runRaycastImport() }
                            .disabled(!isRaycastExport || passphrase.isEmpty || selection.isEmpty)
                    }
                } label: {
                    Text("Import")
                }
                if let status { statusRow(status) }
            } header: {
                SettingsSectionHeader(.backupImportFromRaycast)
            }

            FullBackupAutoExportSection()  // Fork: export on quit

            Section {
                Toggle(isOn: settingsFileSync) {
                    SettingsRowTitle(.backupSettingsFile, "Sync settings file")
                    Text(BackupActions.settingsFilePath)
                }
                if core.settings.settingsFileEnabled {
                    LabeledContent {
                        Button("Show in Finder", action: BackupActions.revealSettingsFile)
                    } label: {
                        Text("Settings changed here are written to the file, and edits to it apply here.")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                SettingsSectionHeader(.backupSettingsFile)
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.backup)
        .onDisappear { if !importingBackup { discardStagedBackup() } }
    }

    @ViewBuilder
    private var conflictNotice: some View {
        if raycastRunning {
            LabeledContent {
                Button("Quit Raycast") { BackupActions.quitRaycast() }
            } label: {
                Label(
                    "Raycast is running — quit it to avoid hotkey conflicts.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        } else {
            Label(
                "Unset matching Raycast shortcuts to avoid conflicts.",
                systemImage: "info.circle"
            )
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusRow(_ status: Status) -> some View {
        switch status {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var backupFileSubtitle: String {
        guard let name = backupFile?.lastPathComponent else {
            return String(localized: "A .tinycast file exported from Tinycast.")
        }
        return openedManifest == nil ? String(localized: "\(name) — couldn't be read") : name
    }

    private func available(in manifest: BackupManifest) -> [BackupCategory: Int] {
        Dictionary(
            uniqueKeysWithValues: BackupCategory.ordered(manifest.categories).map {
                ($0, manifest.count($0))
            })
    }

    private func runExport() {
        guard !exporting else { return }
        exporting = true
        backupStatus = nil
        let categories = exportSelection
        Task {
            defer { exporting = false }
            do {
                // Fork: one file with the full backup's sections beside the categories.
                let result = try await FullBackupActions.exportWithPanel(
                    core: core, categories: categories, draft: full)
                backupStatus = .success(FullBackupActions.exportText(result))
            } catch is CancellationError {
                // The user closed the save panel; nothing to report.
            } catch {
                backupStatus = .failure(error.localizedDescription)
            }
        }
    }

    private func chooseBackupFile() {
        guard let url = BackupActions.chooseBackupFile() else { return }
        discardStagedBackup()
        backupFile = url
        backupStatus = nil
        Task {
            do {
                let (staging, manifest) = try await BackupActions.openBackup(at: url)
                openedStaging = staging
                openedManifest = manifest
                importSelection = manifest.categories
                full.open(bundleRoot: staging.root)  // Fork: full backup
            } catch {
                backupStatus = .failure(error.localizedDescription)
            }
        }
    }

    private func runBackupImport() {
        // Fork: the full backup's sections count as a choice too.
        guard let staging = openedStaging, !importingBackup, !importSelection.isEmpty || full.hasImportChoice
        else {
            return
        }
        importingBackup = true
        let categories = importSelection
        Task {
            defer { importingBackup = false }
            // Fork: keys opened and launchable commands confirmed before anything is applied.
            let request: FullBackupRestore.Request?
            do {
                request = try await FullBackupActions.prepareImport(full, core: core)
            } catch {
                backupStatus = .failure(error.localizedDescription)
                return
            }
            guard let request else { return }
            let summary = await BackupActions.applyBackup(
                categories, from: staging, to: core)
            // Fork: the full backup's sections, after the categories they may point at.
            let report = summary == nil ? nil : await FullBackupRestore.apply(request, to: core)
            // Staged files are adopted by the stores during apply, so the tree goes either way.
            discardStagedBackup()
            backupFile = nil
            if let summary {
                // Fork: one status for both halves.
                backupStatus = .success(FullBackupActions.importText(summary, report))
            }
        }
    }

    /// The extracted tree can run to gigabytes, so leaving the pane must not strand it.
    private func discardStagedBackup() {
        openedStaging?.discard()
        openedStaging = nil
        openedManifest = nil
        full.close()  // Fork: full backup
    }

    private func chooseRaycastFile() {
        guard let url = BackupActions.pickRaycastFile() else { return }
        raycastFile = url
        isRaycastExport = BackupActions.isRaycastExport(url)
        status = nil
    }

    private func runRaycastImport() {
        guard let file = raycastFile, isRaycastExport, !passphrase.isEmpty, !selection.isEmpty,
            !importing
        else { return }
        importing = true
        status = nil
        Task {
            defer { importing = false }
            do {
                let outcome = try await BackupActions.importRaycast(
                    core: core, file: file, passphrase: passphrase, options: selection)
                status = .success(BackupActions.raycastText(outcome))
                passphrase = ""
            } catch {
                status = .failure(error.localizedDescription)
            }
        }
    }
}
