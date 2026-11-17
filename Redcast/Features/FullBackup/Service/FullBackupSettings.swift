import Foundation
import Observation

/// The quit-time export's switch, folder and retention; per Mac, so no backup carries them.
@MainActor
@Observable
final class FullBackupSettings {
    private static let autoExportKey = "fullBackupAutoExport"
    private static let daysKey = "fullBackupAutoExportDays"
    private static let keepKey = "fullBackupAutoExportKeep"
    private static let folderKey = "fullBackupAutoExportFolder"
    private static let lastExportKey = "fullBackupLastExport"

    @ObservationIgnored private let defaults: UserDefaults

    var autoExport: Bool {
        didSet { defaults.set(autoExport, forKey: Self.autoExportKey) }
    }
    var days: Int {
        didSet { defaults.set(days, forKey: Self.daysKey) }
    }
    var keep: Int {
        didSet { defaults.set(keep, forKey: Self.keepKey) }
    }
    /// `~`-relative where it can be, like the snippets and notes folders.
    var folder: String? {
        didSet { defaults.set(folder, forKey: Self.folderKey) }
    }
    /// Any export counts, the pane's own included, so a quit after one never writes another.
    private(set) var lastExport: Date? {
        didSet { defaults.set(lastExport, forKey: Self.lastExportKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoExport = defaults.bool(forKey: Self.autoExportKey)
        days = (defaults.object(forKey: Self.daysKey) as? Int) ?? 7
        keep = (defaults.object(forKey: Self.keepKey) as? Int) ?? 5
        folder = defaults.string(forKey: Self.folderKey)
        lastExport = defaults.object(forKey: Self.lastExportKey) as? Date
    }

    var folderURL: URL? {
        guard let folder, AppPaths.isFolderPath(folder) else { return nil }
        return URL(filePath: (folder as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    func noteExport(at date: Date) {
        lastExport = date
    }
}
