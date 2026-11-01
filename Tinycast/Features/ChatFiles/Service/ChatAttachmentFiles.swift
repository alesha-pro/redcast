import CryptoKit
import Foundation

/// Quick Look and apps read files, so a sent attachment is copied out when it is asked for.
enum ChatAttachmentFiles {
    /// Temporary, per channel: gone on quit, or purged by macOS after a crash.
    nonisolated static var root: URL {
        let folder = (Bundle.main.bundleIdentifier ?? "com.tinycast.app") + ".chat-attachments"
        return FileManager.default.temporaryDirectory.appending(path: folder, directoryHint: .isDirectory)
    }

    /// A folder per content, so the same attachment is the same path and its preview toggles.
    @concurrent
    static func write(_ attachment: ChatAttachmentFile, under root: URL = root) async -> URL? {
        let digest = SHA256.hash(data: attachment.data).prefix(16).map { String(format: "%02x", $0) }
        let folder = root.appending(path: digest.joined(), directoryHint: .isDirectory)
        let file = folder.appending(path: attachment.name, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try attachment.data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    nonisolated static func removeAll(under root: URL = root) {
        try? FileManager.default.removeItem(at: root)
    }
}
