import Foundation

@main
@MainActor
struct BundleMigrationTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() { passes += 1 } else { failures += 1; print("FAIL: \(message)") }
    }

    static func main() {
        onlyRedcastMigrates()
        keychainFallsBackToTheOldService()
        foldersMoveOnlyIntoEmptyPlaces()
        newDefaultsWinOverOld()
        aRealRunMovesAndLinks()
        print("bundle-migration-test: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func onlyRedcastMigrates() {
        expect(LegacyBundleMigration.applies(to: "io.redcast.app"), "Redcast's id migrates")
        expect(!LegacyBundleMigration.applies(to: "com.tinycast.app"), "upstream never migrates")
        expect(!LegacyBundleMigration.applies(to: "com.tinycast.app.dev"), "a Debug build never migrates")
        expect(!LegacyBundleMigration.applies(to: LegacyBundleMigration.legacyID), "the old id never migrates")
        expect(!LegacyBundleMigration.applies(to: nil), "no id, no migration")
    }

    static func keychainFallsBackToTheOldService() {
        expect(LegacyBundleMigration.legacyService(scope: "ai-api-keys", bundleID: "io.redcast.app")
            == "com.tinycast.app.fork.ai-api-keys", "the old service name")
        expect(LegacyBundleMigration.legacyService(scope: "ai-api-keys", bundleID: "com.tinycast.app") == nil,
               "upstream has no old service")
    }

    static func foldersMoveOnlyIntoEmptyPlaces() {
        let home = URL(filePath: "/Users/x", directoryHint: .isDirectory)
        let oldSupport = home.appending(path: "Library/Application Support/com.tinycast.app.fork").path
        let newSupport = home.appending(path: "Library/Application Support/io.redcast.app").path
        let oldConfig = home.appending(path: ".config/tinycast-fork").path
        var folders: Set<String> = [oldSupport, oldConfig]
        var existing: Set<String> = folders
        func run() -> [LegacyBundleMigration.Move] {
            LegacyBundleMigration.moves(home: home, bundleID: "io.redcast.app",
                                        isFolder: { folders.contains($0.path) },
                                        exists: { existing.contains($0.path) })
        }
        let both = run()
        expect(both.count == 2, "Application Support and settings.json's folder both move")
        expect(both.first?.to.path == newSupport, "into the new id's folder")
        expect(both.last?.to.lastPathComponent == "redcast", "settings.json moves to ~/.config/redcast")
        existing.insert(newSupport)
        expect(run().count == 1, "a new folder that already exists is never overwritten")
        folders.remove(oldConfig)
        expect(run().isEmpty, "a link left by an earlier move (not a folder) does not move again")
    }

    static func newDefaultsWinOverOld() {
        let merged = LegacyBundleMigration.mergedDefaults(
            legacy: ["a": 1, "b": "old"], current: ["b": "new", "c": true])
        expect(merged["a"] as? Int == 1, "an old key carries over")
        expect(merged["b"] as? String == "new", "a key the new id wrote wins")
        expect(merged["c"] as? Bool == true, "a new key stays")
    }

    static func aRealRunMovesAndLinks() {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "bundle-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: home) }
        let old = home.appending(path: "Library/Application Support/com.tinycast.app.fork", directoryHint: .isDirectory)
        try? fm.createDirectory(at: old, withIntermediateDirectories: true)
        try? Data("chats".utf8).write(to: old.appending(path: "ai-chats.sqlite3"))
        let suite = "bundle-migration-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { expect(false, "a defaults suite"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        LegacyBundleMigration.runIfNeeded(bundleID: "io.redcast.app", home: home, defaults: defaults, fileManager: fm)
        let new = home.appending(path: "Library/Application Support/io.redcast.app", directoryHint: .isDirectory)
        expect(fm.fileExists(atPath: new.appending(path: "ai-chats.sqlite3").path), "the data moved")
        let link = try? fm.destinationOfSymbolicLink(atPath: old.path)
        expect(link == new.path, "the old path is a link to the new folder")
        expect(defaults.bool(forKey: LegacyBundleMigration.doneKey), "the run is recorded")
        try? fm.removeItem(at: new.appending(path: "ai-chats.sqlite3"))
        LegacyBundleMigration.runIfNeeded(bundleID: "io.redcast.app", home: home, defaults: defaults, fileManager: fm)
        expect(!fm.fileExists(atPath: new.appending(path: "ai-chats.sqlite3").path), "a second launch does nothing")
    }
}
