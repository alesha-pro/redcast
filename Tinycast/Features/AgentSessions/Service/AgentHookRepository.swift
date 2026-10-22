import Foundation
import Security

/// Reads and writes the agents' hook files with backups and a revision check.
enum AgentHookRepository {
    struct Snapshot: Equatable, Sendable {
        let target: AgentHookTarget
        let url: URL
        /// Nil: the file does not exist.
        let text: String?
        let modified: Date?
        /// False when the file exists but is not UTF-8 text the hub can show.
        let isReadable: Bool
        /// The agent's own folder exists, which is when the hub offers to touch its file.
        let isAgentPresent: Bool
    }

    enum Failure: Error, Equatable {
        /// The file moved on since it was diffed; the panel re-reads and shows it again.
        case changed(AgentHookTarget)
        case writeFailed(String)
    }

    static let backupsKept = 5
    /// Larger than any settings file a person writes; past it the hub refuses rather than reads.
    private static let sizeCap = 4 * 1_048_576

    static func url(for target: AgentHookTarget, home: URL) -> URL {
        home.appending(path: target.relativePath, directoryHint: .notDirectory)
    }

    @concurrent static func snapshot(_ target: AgentHookTarget, home: URL) async -> Snapshot {
        read(target, at: url(for: target, home: home))
    }

    /// Every file is re-read before any is written, so one that moved on leaves them all untouched.
    @concurrent static func apply(
        _ changes: [AgentHookFileFormat.Change], expected: [AgentHookTarget: Snapshot], backups: URL, now: Date
    ) async throws(Failure) {
        var checked: [(AgentHookFileFormat.Change, Snapshot)] = []
        for change in changes {
            guard let snapshot = expected[change.target], read(change.target, at: snapshot.url).text == snapshot.text
            else { throw .changed(change.target) }
            checked.append((change, snapshot))
        }
        for (change, snapshot) in checked {
            try write(change, expected: snapshot, backups: backups, now: now)
        }
    }

    @concurrent static func loadLiveStatus(_ url: URL) async -> LiveStatusRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return LiveStatusRecord.decode(data)
    }

    /// Nil deletes the record: live status is off exactly when the file is gone.
    @concurrent static func saveLiveStatus(_ record: LiveStatusRecord?, to url: URL) async {
        guard let record else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(record), (try? data.write(to: url, options: .atomic)) != nil
        else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 16 random bytes as hex; a random UUID's bits stand in should the generator ever refuse.
    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private

    /// Re-reads first and refuses a file that changed; the original is copied before it is touched.
    private static func write(
        _ change: AgentHookFileFormat.Change, expected: Snapshot, backups: URL, now: Date
    ) throws(Failure) {
        let current = read(change.target, at: expected.url)
        guard current.text == expected.text, current.text == change.before else { throw .changed(change.target) }
        let fileManager = FileManager.default
        if let before = change.before {
            try saveBackup(before, target: change.target, folder: backups, now: now)
        }
        // A dotfiles symlink is written through, so the link itself survives.
        let isLink = (try? expected.url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        let destination = isLink ? expected.url.resolvingSymlinksInPath() : expected.url
        let permissions = (try? fileManager.attributesOfItem(atPath: destination.path))?[.posixPermissions]
        do {
            guard let after = change.after ?? (isLink ? "{}\n" : nil) else {
                try fileManager.removeItem(at: destination)
                return
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(after.utf8).write(to: destination, options: .atomic)
            if let permissions {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
            }
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }

    private static func read(_ target: AgentHookTarget, at url: URL) -> Snapshot {
        var isDirectory: ObjCBool = false
        let folder = url.deletingLastPathComponent().path
        let present = FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let attributes else {
            return Snapshot(
                target: target, url: url, text: nil, modified: nil, isReadable: true, isAgentPresent: present)
        }
        let modified = attributes[.modificationDate] as? Date
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= sizeCap, let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)
        else {
            return Snapshot(
                target: target, url: url, text: nil, modified: modified, isReadable: false, isAgentPresent: present)
        }
        return Snapshot(
            target: target, url: url, text: text, modified: modified, isReadable: true, isAgentPresent: present)
    }

    private static func saveBackup(_ text: String, target: AgentHookTarget, folder: URL, now: Date) throws(Failure) {
        let fileManager = FileManager.default
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: now)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        let url = folder.appending(path: "\(target.rawValue)-\(stamp).json", directoryHint: .notDirectory)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
        let kept = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(target.rawValue + "-") && $0.hasSuffix(".json") }
            .sorted(by: >)
        for name in kept.dropFirst(backupsKept) {
            try? fileManager.removeItem(at: folder.appending(path: name, directoryHint: .notDirectory))
        }
    }
}
