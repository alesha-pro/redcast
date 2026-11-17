import Foundation

/// Redcast's own bundle id replaced the fork's old one (`com.tinycast.app.fork`). On the first launch
/// under the new id this carries everything the old id kept: settings, Application Support and the
/// settings.json mirror. Keychain items move lazily (`KeychainSecretStore`). See bundle-migration.md.
enum LegacyBundleMigration {
    static let legacyID = "com.tinycast.app.fork"
    /// Set in the new domain once the move ran; a second launch does nothing.
    static let doneKey = "legacyBundleMigrationDone"

    /// Only Redcast's own ids migrate, so a Debug build or upstream's Tinycast never touches fork data.
    static func applies(to bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID == "io.redcast.app"
    }

    /// The Keychain service an item had under the old id, for a lazy move; nil when nothing migrates.
    static func legacyService(scope: String, bundleID: String?) -> String? {
        applies(to: bundleID) ? "\(legacyID).\(scope)" : nil
    }

    struct Move: Equatable {
        let from: URL
        let to: URL
    }

    /// The folders that move, old → new. A folder moves only when the old one is a real folder and the
    /// new one does not exist yet, so a half-run or a later launch never overwrites newer data.
    static func moves(home: URL, bundleID: String, isFolder: (URL) -> Bool, exists: (URL) -> Bool) -> [Move] {
        let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let config = home.appending(path: ".config", directoryHint: .isDirectory)
        let candidates = [
            Move(from: support.appending(path: legacyID, directoryHint: .isDirectory),
                 to: support.appending(path: bundleID, directoryHint: .isDirectory)),
            Move(from: config.appending(path: "tinycast-fork", directoryHint: .isDirectory),
                 to: config.appending(path: "redcast", directoryHint: .isDirectory)),
        ]
        return candidates.filter { isFolder($0.from) && !exists($0.to) }
    }

    /// The old domain's keys under the new domain's: whatever the new id already wrote wins.
    static func mergedDefaults(legacy: [String: Any], current: [String: Any]) -> [String: Any] {
        legacy.merging(current) { _, new in new }
    }

    /// Runs once, before anything reads settings. A failure leaves the old data where it was.
    static func runIfNeeded(
        bundleID: String? = Bundle.main.bundleIdentifier,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        guard applies(to: bundleID), let bundleID, !defaults.bool(forKey: doneKey) else { return }
        if let legacy = defaults.persistentDomain(forName: legacyID), !legacy.isEmpty {
            let current = defaults.persistentDomain(forName: bundleID) ?? [:]
            defaults.setPersistentDomain(mergedDefaults(legacy: legacy, current: current), forName: bundleID)
        }
        let isFolder: (URL) -> Bool = { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
        let exists: (URL) -> Bool = { fileManager.fileExists(atPath: $0.path) }
        for move in moves(home: home, bundleID: bundleID, isFolder: isFolder, exists: exists) {
            do {
                try fileManager.createDirectory(at: move.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: move.from, to: move.to)
                // The old path stays a link, so a rolled-back build and stored absolute paths still resolve.
                try? fileManager.createSymbolicLink(at: move.from, withDestinationURL: move.to)
            } catch {
                NSLog("Redcast: could not move %@ to %@: %@", move.from.path, move.to.path, "\(error)")
            }
        }
        defaults.set(true, forKey: doneKey)
    }
}
