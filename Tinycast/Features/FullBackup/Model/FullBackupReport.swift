import Foundation

/// What a full import did and what it left for the reader, so nothing it skipped is silent.
struct FullBackupReport: Sendable, Equatable {
    var applied: [FullBackupSection: Int] = [:]
    var secretsRestored = 0
    var pausedSchedules: [String] = []
    var disabledServers: [String] = []
    var backgroundCommands: [String] = []
    var consents: [FullBackupConsent] = []
    var missingExtensions: [String] = []
    var missingFolders: [String] = []
    var droppedRecords = 0
    var skippedSections: [String] = []
    var takenShortcuts = 0
    var signInAgain: [String] = []
    var problems: [String] = []

    var sentences: [String] {
        func list(_ items: [String]) -> String { items.formatted(.list(type: .and)) }
        var parts: [String] = []
        let applied = FullBackupSection.ordered(Set(self.applied.keys)).map { section in
            "\(section.descriptor.label) (\(self.applied[section] ?? 0))"
        }
        if !applied.isEmpty { parts.append(String(localized: "Restored \(list(applied)).")) }
        if secretsRestored > 0 {
            parts.append(String(localized: "API keys and tokens restored: \(secretsRestored)."))
        }
        if !pausedSchedules.isEmpty {
            parts.append(String(localized: "Paused schedules: \(list(pausedSchedules))."))
        }
        if !disabledServers.isEmpty {
            parts.append(String(localized: "MCP servers left off: \(list(disabledServers))."))
        }
        if !backgroundCommands.isEmpty {
            parts.append(String(localized: "Background commands left off: \(list(backgroundCommands))."))
        }
        if !consents.isEmpty {
            let labels = list(consents.map(\.label))
            parts.append(String(localized: "Still off here, turn on in Settings if you want them: \(labels)."))
        }
        if !missingExtensions.isEmpty {
            let names = list(missingExtensions)
            parts.append(
                String(
                    localized: "Install from the Extension Store, then import again for their preferences: \(names)."))
        }
        if !missingFolders.isEmpty {
            parts.append(String(localized: "These agents' folders aren't on this Mac: \(list(missingFolders))."))
        }
        if droppedRecords > 0 {
            parts.append(String(localized: "Records from a newer version skipped: \(droppedRecords)."))
        }
        if !skippedSections.isEmpty {
            parts.append(String(localized: "Sections from a newer version were skipped: \(list(skippedSections))."))
        }
        if !signInAgain.isEmpty {
            parts.append(String(localized: "Sign in with ChatGPT again on this Mac: \(list(signInAgain))."))
        }
        if takenShortcuts > 0 {
            parts.append(String(localized: "Shortcuts already taken here and skipped: \(takenShortcuts)."))
        }
        parts.append(contentsOf: problems)
        return parts
    }
}
