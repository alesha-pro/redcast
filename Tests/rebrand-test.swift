import Foundation

/// Fork: what Redcast renames outside the catalogs, and the upstream names it still answers to.
@main
@MainActor
struct RebrandTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() { passes += 1 } else { failures += 1; print("FAIL: \(message)") }
    }

    static func main() {
        promptsSayRedcast()
        bothSchemesAndBothBackupsAreDeclared()
        print("rebrand-test: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func promptsSayRedcast() {
        expect("You are built into Tinycast.".forkBranded == "You are built into Redcast.", "a sentence")
        expect("Tinycast's own prompt".forkBranded == "Redcast's own prompt", "a possessive")
        expect("Tinycasts Fenster".forkBranded == "Redcasts Fenster", "a German genitive")
        let ids = "tinycast:// .tinycast TinycastAgents Tinycast/Features com.tinycast.app x.Tinycast"
        expect(ids.forkBranded == ids, "ids, schemes, paths and extensions stay")
        expect("Tinycast".forkBranded == "Redcast", "the bare word")
        expect("“Tinycast”, Tinycast-Auto".forkBranded == "“Redcast”, Redcast-Auto", "next to punctuation")
    }

    static func bothSchemesAndBothBackupsAreDeclared() {
        let url = URL(fileURLWithPath: "Tinycast/Info.plist")
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return expect(false, "Info.plist reads") }
        let schemes = (plist["CFBundleURLTypes"] as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        expect(schemes.contains("redcast"), "redcast:// is registered")
        expect(schemes.contains("tinycast"), "and tinycast:// still is, for hooks and links already out there")
        let types = plist["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
        func extensions(of id: String) -> [String] {
            let type = types.first { $0["UTTypeIdentifier"] as? String == id }
            let tags = type?["UTTypeTagSpecification"] as? [String: Any]
            return tags?["public.filename-extension"] as? [String] ?? []
        }
        expect(extensions(of: "io.redcast.backup") == ["redcast"], "Redcast's backups are .redcast")
        expect(extensions(of: "com.tinycast.backup") == ["tinycast"], "and .tinycast is still a backup")
        let source = (try? String(contentsOfFile: "Tinycast/Features/Backup/Service/BackupActions.swift", encoding: .utf8)) ?? ""
        expect(
            source.contains("chooseFile(ofTypes: [.redcastBackup, .tinycastBackup])"),
            "Import Backup lets both kinds be picked")
    }
}
