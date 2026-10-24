import Foundation

/// Fails when a store appears that `FullBackupCoverage` has no decision for. Run from the repo root.
@main
struct FullBackupCoverageTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ description: String, _ condition: Bool) {
        print("\(condition ? "PASS" : "FAIL")  \(description)")
        if !condition { failures += 1 }
    }

    static func naming(_ description: String, _ items: [String]) -> String {
        items.isEmpty ? description : "\(description): \(items.sorted().joined(separator: ", "))"
    }

    /// A file that touches one of these persists something, so its literal keys and names count.
    static let markers = [
        "UserDefaults", "defaults.set(", "applicationSupport", "KeychainSecretStore(scope:", "sqlite3_open",
        ".write(to:"
    ]
    /// The coverage table itself, generated data, and the backup's own file layouts.
    static let skipped = [
        "FullBackupCoverage.swift", ".generated.swift", "FullBackupLayout.swift", "BackupBundle.swift"
    ]

    static func main() {
        let sources = swiftSources(under: URL(fileURLWithPath: "Tinycast", isDirectory: true))
        check("the scan finds the app's sources", sources.count > 100)
        settingsKeys()
        consents()
        scan(sources)
        nothingStale(sources)
        reasons()
        sectionsAreClaimed()
        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - AppSettingsKey

    static func settingsKeys() {
        let upstream = Set(SettingsBackupCoverage.mirrored.values.map(\.rawValue))
        let excludedUpstream = Set(SettingsBackupCoverage.deliberatelyExcluded.keys)
        let fork = Set(FullBackupCoverage.settingsKeys.keys.map(\.rawValue))
        let undecided = AppSettingsKey.allCases.map(\.rawValue).filter {
            !upstream.contains($0) && !fork.contains($0)
        }
        check(naming("every AppSettingsKey has a decision", undecided), undecided.isEmpty)
        let twice = fork.intersection(upstream)
        check(naming("no key is carried by upstream and decided again", Array(twice)), twice.isEmpty)
        let leftOut = excludedUpstream.subtracting(fork)
        check(naming("every key upstream leaves out has a fork decision", Array(leftOut)), leftOut.isEmpty)
    }

    static func consents() {
        let decisions = FullBackupCoverage.settingsKeys
        let unrecorded = FullBackupConsent.allCases.filter { consent in
            switch decisions[consent.settingsKey] {
            case .consent, .section: return false
            default: return true
            }
        }
        check(
            naming("every consent records a key a section carries", unrecorded.map(\.rawValue)),
            unrecorded.isEmpty)
        let recorded = Set(FullBackupConsent.allCases.map(\.settingsKey))
        let unnamed = decisions.compactMap { key, decision -> String? in
            if case .consent = decision, !recorded.contains(key) { return key.rawValue }
            return nil
        }
        check(naming("every consent decision has a FullBackupConsent case", unnamed), unnamed.isEmpty)
        for key in [
            AppSettingsKey.snippetsEnabled, .extensionsEnabled, .mcpEnabled, .aiEnabled, .quickActionsEnabled,
            .voiceCloudDictation, .screenAwarenessEnabled, .calendarEnabled, .autoJoinMeetings
        ] {
            let decision = decisions[key]
            var isConsent = false
            if case .consent = decision { isConsent = true }
            check("\(key.rawValue) is recorded, never applied", isConsent)
        }
        if case .excluded = decisions[.extensionsAIGrants] {
            check("extension AI grants never travel", true)
        } else {
            check("extension AI grants never travel", false)
        }
    }

    // MARK: - The scan

    static func scan(_ sources: [(path: String, text: String)]) {
        var keys: [String: String] = [:]
        var files: [String: String] = [:]
        var scopes: [String: String] = [:]
        for (path, text) in sources where markers.contains(where: text.contains) {
            for key in matches(#"forKey:\s*"([^"]+)""#, in: text)
                + matches(#"(?:let|var)\s+\w*[Kk]ey\w*(?:\s*:\s*String)?\s*=\s*"([^"]+)""#, in: text)
                + matches(#"recoveryKey:\s*String\s*=\s*"([^"]+)""#, in: text)
            {
                keys[key] = path
            }
            for name in matches(#"appendingPathComponent\(\s*"([^"]+)""#, in: text)
                + matches(#"appending\(\s*path:\s*"([^"]+)""#, in: text)
            {
                files[name] = path
            }
            for scope in matches(#"KeychainSecretStore\(scope:\s*"([^"]+)""#, in: text) {
                scopes[scope] = path
            }
        }
        let probes = ["fallbackOrder", "fullBackupLastExport", "extensionAppearances", "hiddenMeetingCalendars"]
        let names = ["agents.json", "quick-actions.json", "ai-chats.sqlite3", "extension-data", "ai-chat-workspace.json"]
        check(
            "the scan sees the stores it guards",
            probes.allSatisfy(keys.keys.contains) && names.allSatisfy(files.keys.contains))
        let knownKeys = Set(FullBackupCoverage.defaultsKeys.keys).union(AppSettingsKey.allCases.map(\.rawValue))
        let newKeys = keys.filter { !knownKeys.contains($0.key) }.map { "\($0.key) (\($0.value))" }
        check(naming("every UserDefaults key in a store has a decision", newKeys), newKeys.isEmpty)
        let newFiles = files.filter { FullBackupCoverage.files[$0.key] == nil }.map { "\($0.key) (\($0.value))" }
        check(naming("every Application Support name in a store has a decision", newFiles), newFiles.isEmpty)
        let newScopes = scopes.filter { FullBackupCoverage.keychainScopes[$0.key] == nil }.map(\.key)
        check(naming("every Keychain scope has a decision", newScopes), newScopes.isEmpty)
        check("the scan reaches the Keychain scopes", scopes.count >= 6)
        let hotkeys = sources.contains { $0.path.hasSuffix("HotKeyAction.swift") && $0.text.contains("\"hotkey.") }
        check(
            "per-action hotkey keys are decided as one family",
            hotkeys && FullBackupCoverage.defaultsKeys["hotkey.*"] != nil)
    }

    /// A decision whose literal no source spells any more is rot: delete it with its store.
    static func nothingStale(_ sources: [(path: String, text: String)]) {
        let corpus = sources.filter { !$0.path.hasSuffix("FullBackupCoverage.swift") }.map(\.text).joined()
        let names = Array(FullBackupCoverage.defaultsKeys.keys) + Array(FullBackupCoverage.files.keys)
            + Array(FullBackupCoverage.keychainScopes.keys)
        let stale = names.filter { $0 != "hotkey.*" && !corpus.contains("\"\($0)") }
        check(naming("every decision names something the sources still spell", stale), stale.isEmpty)
    }

    static func reasons() {
        var decisions = Array(FullBackupCoverage.settingsKeys.values) + Array(FullBackupCoverage.defaultsKeys.values)
        decisions += Array(FullBackupCoverage.files.values) + Array(FullBackupCoverage.keychainScopes.values)
        let empty = decisions.filter { decision in
            switch decision {
            case .excluded(let reason), .notState(let reason): return !reason.contains(" ") || reason.count < 12
            default: return false
            }
        }
        check("every exclusion carries a real reason", empty.isEmpty)
        let unsealed = FullBackupCoverage.keychainScopes.filter { _, decision in
            if decision == .secrets { return false }
            if case .excluded = decision { return false }
            return true
        }.map(\.key)
        check(naming("every Keychain scope travels sealed or not at all", unsealed), unsealed.isEmpty)
        var codexExcluded = false
        if case .excluded = FullBackupCoverage.keychainScopes["codex-plan-credentials"] { codexExcluded = true }
        check("a ChatGPT sign-in never travels, even sealed", codexExcluded)
    }

    static func sectionsAreClaimed() {
        var claimed = Set<FullBackupSection>()
        let all = Array(FullBackupCoverage.settingsKeys.values) + Array(FullBackupCoverage.defaultsKeys.values)
            + Array(FullBackupCoverage.files.values)
        for decision in all {
            if case .section(let section) = decision { claimed.insert(section) }
        }
        let unclaimed = FullBackupSection.allCases.filter { !claimed.contains($0) }.map(\.rawValue)
        check(naming("every section carries some store", unclaimed), unclaimed.isEmpty)
    }

    // MARK: - Helpers

    static func swiftSources(under root: URL) -> [(path: String, text: String)] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard !skipped.contains(where: url.lastPathComponent.hasSuffix),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            found.append((url.path, text))
        }
        return found
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
