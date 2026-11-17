import Foundation
import Observation

/// The Backup pane's fork half: what to export, and what an opened file offers and was picked.
@MainActor
@Observable
final class FullBackupDraft {
    var exportSections = FullBackupSection.exportedByDefault
    var includesSecrets = false
    var passphrase = ""
    var passphraseAgain = ""

    private(set) var layout: FullBackupLayout?
    private(set) var preview = FullBackupPreview()
    var importSections: Set<FullBackupSection> = []
    var modes: [FullBackupSection: FullBackupImportMode] = [:]
    var importsSecrets = false
    var importPassphrase = ""

    /// nil when ready; otherwise what stops the export.
    var exportProblem: String? {
        guard includesSecrets else { return nil }
        if passphrase.count < FullBackupCipher.minimumPassphraseLength {
            return String(localized: "Use a passphrase of at least 8 characters.")
        }
        return passphrase == passphraseAgain ? nil : String(localized: "The passphrases don't match.")
    }

    var exportPassphrase: String? { includesSecrets && exportProblem == nil ? passphrase : nil }

    var hasImportChoice: Bool { !importSections.isEmpty || importsSecrets }

    var importBlocked: Bool { importsSecrets && importPassphrase.isEmpty }

    func blocksExport(upstream nothingTicked: Bool) -> Bool {
        nothingTicked && exportSections.isEmpty && !includesSecrets || exportProblem != nil
    }

    func blocksImport(upstream nothingTicked: Bool) -> Bool {
        nothingTicked && !hasImportChoice || importBlocked
    }

    func open(bundleRoot: URL) {
        let layout = FullBackupLayout(bundleRoot: bundleRoot)
        self.layout = layout
        preview = layout.preview()
        importSections = Set(preview.available.keys)
        modes = [:]
        importsSecrets = false
        importPassphrase = ""
    }

    func close() {
        layout = nil
        preview = FullBackupPreview()
        importSections = []
        importsSecrets = false
        importPassphrase = ""
    }

    func clearExportPassphrase() {
        passphrase = ""
        passphraseAgain = ""
    }

    func mode(for section: FullBackupSection) -> FullBackupImportMode {
        modes[section] ?? .merge
    }
}
