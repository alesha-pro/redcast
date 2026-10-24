import AppKit
import Foundation

/// Export, open and import with the fork's sections beside upstream's categories, in one file.
@MainActor
enum FullBackupActions {
    struct ExportResult: Sendable {
        var upstream: BackupComposer.Result
        var contents: FullBackupContents
    }

    /// What the quit-time export carries: no clipboard, chats or secrets, which only a person picks.
    static let automaticCategories: Set<BackupCategory> = [.configuration, .snippets, .notes, .learning]

    static func export(
        core: AppCore, categories: Set<BackupCategory>, sections: Set<FullBackupSection>,
        passphrase: String?, to destination: URL
    ) async throws -> ExportResult {
        let plan = BackupComposer.plan(categories, from: core)
        let full = FullBackupComposer.plan(sections, passphrase: passphrase, from: core)
        let result = try await Task.detached(priority: .userInitiated) {
            let staging = try BackupStaging()
            defer { staging.discard() }
            let upstream = try BackupComposer.write(plan, into: staging.bundle)
            let layout = FullBackupLayout(bundleRoot: staging.root)
            let contents = try FullBackupComposer.write(full, into: layout)
            try BackupArchive.seal(directory: staging.root, into: destination)
            return ExportResult(upstream: upstream, contents: contents)
        }.value
        core.fullBackupSettings.noteExport(at: Date())
        return result
    }

    static func exportWithPanel(
        core: AppCore, categories: Set<BackupCategory>, draft: FullBackupDraft
    ) async throws -> ExportResult {
        guard
            let destination = BackupActions.chooseSaveLocation(named: "Tinycast", type: .tinycastBackup)
        else { throw CancellationError() }
        let result = try await export(
            core: core, categories: categories, sections: draft.exportSections,
            passphrase: draft.exportPassphrase, to: destination)
        draft.clearExportPassphrase()
        return result
    }

    static func exportText(_ result: ExportResult) -> String {
        var labels = BackupCategory.ordered(result.upstream.manifest.categories).map(\.descriptor.label)
        let sections = Set(result.contents.sections.keys.compactMap(FullBackupSection.init(rawValue:)))
        labels += FullBackupSection.ordered(sections).map(\.descriptor.label)
        if result.contents.secrets != nil { labels.append(String(localized: "sealed API keys and tokens")) }
        var text =
            labels.isEmpty
            ? String(localized: "Nothing was selected.")
            : String(localized: "Saved \(labels.formatted(.list(type: .and))).")
        if result.upstream.missingImages > 0 {
            let missing = result.upstream.missingImages
            text += " " + String(localized: "\(missing) images were unavailable and skipped.")
        }
        return text
    }

    // MARK: - Launcher commands

    /// No picker in the launcher, so everything but the opt-ins: chats and sealed keys.
    static func runExportCommand(core: AppCore) async {
        do {
            guard
                let destination = BackupActions.chooseSaveLocation(named: "Tinycast", type: .tinycastBackup)
            else { return }
            let result = try await export(
                core: core, categories: BackupCategory.all, sections: FullBackupSection.exportedByDefault,
                passphrase: nil, to: destination)
            await core.showNotice(
                title: String(localized: "Backup Exported"), message: exportText(result),
                symbol: "square.and.arrow.up", tone: .success)
        } catch {
            await core.showNotice(
                title: String(localized: "Export Failed"), message: error.localizedDescription,
                symbol: "square.and.arrow.up", tone: .danger)
        }
    }

    /// Everything the file holds, merged; sealed keys need the pane, which can ask for a passphrase.
    static func runImportCommand(core: AppCore) async {
        guard let file = BackupActions.chooseBackupFile() else { return }
        do {
            let (staging, manifest) = try await BackupActions.openBackup(at: file)
            defer { staging.discard() }
            let draft = FullBackupDraft()
            draft.open(bundleRoot: staging.root)
            guard let request = try await prepareImport(draft, core: core),
                let summary = await BackupActions.applyBackup(manifest.categories, from: staging, to: core)
            else { return }
            let report = await FullBackupRestore.apply(request, to: core)
            await core.showNotice(
                title: String(localized: "Backup Imported"), message: importText(summary, report),
                symbol: "square.and.arrow.down", tone: .success)
        } catch {
            await core.showNotice(
                title: String(localized: "Import Failed"), message: error.localizedDescription,
                symbol: "square.and.arrow.down", tone: .danger)
        }
    }

    // MARK: - Import

    /// Opens the secrets and asks about launchable commands before anything is applied.
    static func prepareImport(
        _ draft: FullBackupDraft, core: AppCore
    ) async throws -> FullBackupRestore.Request? {
        guard let layout = draft.layout else { return nil }
        let sections = draft.importSections.intersection(draft.preview.available.keys)
        var secrets: FullBackupSecrets?
        if draft.importsSecrets, let header = draft.preview.secrets, let sealed = layout.readSecrets() {
            let passphrase = draft.importPassphrase
            let plaintext = try await Task.detached(priority: .userInitiated) {
                try FullBackupCipher.open(sealed, header: header, passphrase: passphrase)
            }.value
            secrets = try FullBackupLayout.decoder.decode(FullBackupSecrets.self, from: plaintext)
        }
        let launches = FullBackupImportPolicy.launches(
            agents: sections.contains(.agents) ? layout.read(AgentsBackup.self, for: .agents) : nil,
            mcp: sections.contains(.mcpServers) ? layout.read(MCPBackup.self, for: .mcpServers) : nil,
            ai: sections.contains(.ai) ? layout.read(AIBackup.self, for: .ai) : nil)
        if !launches.isEmpty {
            let list = launches.map { "• " + $0 }.joined(separator: "\n")
            let confirmed = await core.confirm(
                title: String(localized: "Import commands Tinycast can launch?"),
                message: String(
                    localized: """
                        This backup names programs its agents, MCP servers and AI tools start:
                        \(list)
                        Servers and schedules arrive switched off. Only import files you trust.
                        """),
                symbol: "square.and.arrow.down", confirmTitle: String(localized: "Import"),
                confirmRole: .standard)
            guard confirmed else { return nil }
        }
        return FullBackupRestore.Request(
            layout: layout, sections: sections, modes: draft.modes, secrets: secrets,
            skipped: draft.preview.skipped)
    }

    /// Upstream's sentence only when it says something, so a fork-only import never reads empty.
    static func importText(_ summary: BackupApplier.Summary, _ report: FullBackupReport?) -> String {
        let upstream = BackupActions.summaryText(summary)
        var parts = upstream == BackupActions.nothingImportedText ? [] : [upstream]
        parts += report?.sentences ?? []
        return parts.isEmpty ? BackupActions.nothingImportedText : parts.joined(separator: " ")
    }

    // MARK: - On quit

    /// Awaited by the quit itself, so it never runs a timer and never outlives the app.
    static func exportOnQuitIfDue(core: AppCore) async {
        let settings = core.fullBackupSettings
        let now = Date()
        guard settings.autoExport, let folder = settings.folderURL,
            FullBackupAutoExportPolicy.isDue(lastExport: settings.lastExport, now: now, days: settings.days)
        else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(FullBackupAutoExportPolicy.fileName(at: now))
            _ = try await export(
                core: core, categories: automaticCategories, sections: automaticSections, passphrase: nil,
                to: destination)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in FullBackupAutoExportPolicy.pruned(names, keeping: settings.keep) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        } catch {
            NSLog("Tinycast: automatic backup failed: \(error.localizedDescription)")
        }
    }

    static var automaticSections: Set<FullBackupSection> {
        FullBackupSection.exportedByDefault.subtracting([.chatHistory])
    }

    static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}
