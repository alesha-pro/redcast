import Foundation

/// The `full/` tree inside a staged bundle; an older reader never looks in it.
struct FullBackupLayout: Sendable {
    let root: URL

    init(bundleRoot: URL) {
        root = bundleRoot.appendingPathComponent("full", isDirectory: true)
    }

    var contentsURL: URL { root.appendingPathComponent("contents.json") }
    var secretsURL: URL { root.appendingPathComponent("secrets.sealed") }
    var chatsDirectory: URL { root.appendingPathComponent("chats", isDirectory: true) }
    var chatDatabaseURL: URL { chatsDirectory.appendingPathComponent("ai-chats.sqlite3") }
    var chatSummariesDirectory: URL {
        chatsDirectory.appendingPathComponent("summaries", isDirectory: true)
    }

    func payloadURL(_ section: FullBackupSection) -> URL {
        root.appendingPathComponent("\(section.rawValue).json")
    }

    // MARK: - Writing

    func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write<Payload: Encodable>(_ payload: Payload, for section: FullBackupSection) throws {
        try Self.encoder.encode(payload).write(to: payloadURL(section), options: .atomic)
    }

    func writeContents(_ contents: FullBackupContents) throws {
        try Self.encoder.encode(contents).write(to: contentsURL, options: .atomic)
    }

    func writeSecrets(_ sealed: Data) throws {
        try sealed.write(to: secretsURL, options: .atomic)
    }

    // MARK: - Reading

    /// nil for a file made before the fork's sections existed: only upstream's categories import.
    func readContents() -> FullBackupContents? {
        guard let data = try? Data(contentsOf: contentsURL) else { return nil }
        return try? Self.decoder.decode(FullBackupContents.self, from: data)
    }

    func preview() -> FullBackupPreview {
        readContents().map(FullBackupPreview.init) ?? FullBackupPreview()
    }

    func read<Payload: Decodable>(_ type: Payload.Type, for section: FullBackupSection) -> Payload? {
        guard let data = try? Data(contentsOf: payloadURL(section)) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    func readSecrets() -> Data? {
        try? Data(contentsOf: secretsURL)
    }

    /// Named files only, each checked, so an archive can't point a summary outside its folder.
    func chatSummaries() -> [(name: String, data: Data)] {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: chatSummariesDirectory.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json"), !name.contains("/"), !name.hasPrefix("."),
                let data = try? Data(contentsOf: chatSummariesDirectory.appendingPathComponent(name))
            else { return nil }
            return (name, data)
        }
    }

    // MARK: - Coding

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Dates keep the stores' own encoding, so a round trip restores them to the instant.
    static let decoder = JSONDecoder()
}
