import Foundation
import Synchronization

/// The history's one file: a line per finished voice input, appended off-main and trimmed by age.
enum DictationHistoryFile {
    static let url = AppPaths.applicationSupport().appending(path: "dictation-history.jsonl")

    /// A trim waits this long past the retention, so the file is rewritten at most hourly.
    static let trimSlack: TimeInterval = 3_600

    /// One writer at a time; a load takes it too, since it may rewrite what aged out.
    private static let writing = Mutex(())

    /// Best effort: a history that cannot be written never touches the dictation it describes.
    nonisolated static func append(
        _ entry: DictationHistoryEntry, retention: DictationHistoryRetention, to url: URL = url
    ) {
        guard retention.keepsHistory else { return }
        writing.withLock { _ in
            let path = url.path
            let manager = FileManager.default
            if !manager.fileExists(atPath: path) {
                guard manager.createFile(atPath: path, contents: nil) else { return }
            }
            guard let handle = try? FileHandle(forUpdating: url) else { return }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd() else { return }
            let cutoff = retention.cutoff(now: entry.date)
            if end > 0, (try? handle.seek(toOffset: end - 1)) != nil,
                (try? handle.read(upToCount: 1)) != Data("\n".utf8)
            {
                // A line a crash cut short would swallow this one, so the rewrite drops it.
                guard let data = try? Data(contentsOf: url) else { return }
                replace(url, with: DictationHistoryEntry.kept(data, since: cutoff) + Data(entry.line.utf8))
                return
            }
            guard (try? handle.write(contentsOf: Data(entry.line.utf8))) != nil, let cutoff else { return }
            try? handle.seek(toOffset: 0)
            let oldest = (try? handle.read(upToCount: 32)).flatMap(DictationHistoryEntry.firstDate(in:))
            guard oldest.map({ $0 < cutoff.addingTimeInterval(-trimSlack) }) ?? true else { return }
            rewrite(url, since: cutoff)
        }
    }

    /// Newest first; on this gesture what aged out since the last write leaves the file too.
    nonisolated static func load(
        retention: DictationHistoryRetention, now: Date, at url: URL = url
    ) -> [DictationHistoryEntry] {
        writing.withLock { _ in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
            let cutoff = retention.cutoff(now: now)
            if let cutoff, let oldest = DictationHistoryEntry.firstDate(in: data.prefix(32)),
                oldest < cutoff
            {
                let kept = DictationHistoryEntry.kept(data, since: cutoff)
                replace(url, with: kept)
                return DictationHistoryEntry.entries(in: kept).reversed()
            }
            return DictationHistoryEntry.entries(in: data, since: cutoff).reversed()
        }
    }

    /// A shorter retention applies at once, Off included, which removes the file.
    nonisolated static func trim(retention: DictationHistoryRetention, now: Date, at url: URL = url) {
        guard let cutoff = retention.cutoff(now: now) else { return }
        writing.withLock { _ in rewrite(url, since: cutoff) }
    }

    nonisolated static func delete(_ ids: Set<UUID>, at url: URL = url) {
        guard !ids.isEmpty else { return }
        writing.withLock { _ in
            guard let data = try? Data(contentsOf: url) else { return }
            replace(url, with: DictationHistoryEntry.kept(data, since: nil, removing: ids))
        }
    }

    /// A retry's result over the line it retried, where that line stands.
    nonisolated static func update(_ entry: DictationHistoryEntry, at url: URL = url) {
        writing.withLock { _ in
            guard let data = try? Data(contentsOf: url) else { return }
            replace(url, with: DictationHistoryEntry.replacing(entry, in: data))
        }
    }

    /// At the user's word, never on its own; a missing file already reads as no history.
    nonisolated static func clear(at url: URL = url) {
        writing.withLock { _ in try? FileManager.default.removeItem(at: url) }
    }

    private static func rewrite(_ url: URL, since cutoff: Date) {
        guard let data = try? Data(contentsOf: url) else { return }
        replace(url, with: DictationHistoryEntry.kept(data, since: cutoff))
    }

    /// Atomic, never shrunk in place under a mapped reader; nothing left is no file at all.
    private static func replace(_ url: URL, with data: Data) {
        guard !data.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
