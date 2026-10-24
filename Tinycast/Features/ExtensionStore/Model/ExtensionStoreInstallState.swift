import Foundation

/// What this Mac has of a store entry, by manifest name as every install path keys it.
enum ExtensionStoreInstallState: Equatable, Sendable {
    case available
    case installed
    /// A store install whose recorded commit is behind the store's, or one Settings found behind.
    case updateAvailable

    /// What the screen needs to know about the installed set, read once per render.
    struct Installed: Sendable, Equatable {
        var names: Set<String> = []
        /// The commit each store-sourced install came from; nil until a check adopted the store's.
        var storeCommits: [String: String?] = [:]
        /// Names Settings' update check already found behind.
        var pendingUpdates: Set<String> = []
    }

    static func of(_ entry: ExtensionStoreEntry, in installed: Installed) -> Self {
        guard installed.names.contains(entry.name) else { return .available }
        if installed.pendingUpdates.contains(entry.name) { return .updateAvailable }
        // A folder or GitHub install is the user's own copy, so the store has nothing newer for it.
        guard let recorded = installed.storeCommits[entry.name], let recorded, let latest = entry.commitSHA
        else { return .installed }
        return recorded == latest ? .installed : .updateAvailable
    }
}
