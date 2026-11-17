import Foundation

/// `full/contents.json`: which fork sections a file holds, at which version, and its secrets header.
struct FullBackupContents: Codable, Sendable, Equatable {
    /// A newer format skips every fork section; the upstream categories still import.
    static let currentFormat = 1

    struct Entry: Codable, Sendable, Equatable {
        var version: Int
        var count: Int
    }

    var format = Self.currentFormat
    /// Keyed by `FullBackupSection.rawValue`, so a name this build lacks still decodes.
    var sections: [String: Entry] = [:]
    var secrets: FullBackupSecretsHeader?
}

/// How the secrets blob was sealed; everything a reader needs except the passphrase.
struct FullBackupSecretsHeader: Codable, Sendable, Equatable {
    static let kdfName = "pbkdf2-sha256"
    static let cipherName = "aes-256-gcm"

    var kdf = Self.kdfName
    var iterations: Int
    var salt: Data
    var cipher = Self.cipherName
    var count: Int
}

/// What an opened file offers, decided before anything is applied.
struct FullBackupPreview: Sendable, Equatable {
    var available: [FullBackupSection: Int] = [:]
    /// Sections this build can't read: unknown names or newer versions, skipped and named.
    var skipped: [String] = []
    var secrets: FullBackupSecretsHeader?

    var isEmpty: Bool { available.isEmpty && secrets == nil }

    init() {}

    init(_ contents: FullBackupContents) {
        guard contents.format <= FullBackupContents.currentFormat else {
            skipped = contents.sections.keys.sorted()
            return
        }
        for (name, entry) in contents.sections {
            guard let section = FullBackupSection(rawValue: name), entry.version <= section.version
            else {
                skipped.append(name)
                continue
            }
            available[section] = entry.count
        }
        skipped.sort()
        secrets = contents.secrets
    }
}
