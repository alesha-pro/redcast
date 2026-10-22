import Foundation
import Synchronization

/// The usage log: an append-only file of replies no chat keeps, trimmed by age as it is written.
enum UsageLedger {
    static let url = AppPaths.applicationSupport().appending(path: "ai-usage.tsv")

    static let retention: TimeInterval = 400 * 86_400
    /// A trim keeps `retention` and waits this much longer, so the file is rewritten about monthly.
    static let trimSlack: TimeInterval = 30 * 86_400

    /// Appends and trims only; a reader needs no lock, since a trim replaces the file whole.
    private static let writing = Mutex(())

    /// Best effort: a log that cannot be written must never touch the reply it describes.
    nonisolated static func append(_ entry: UsageLedgerEntry, to url: URL = url) {
        writing.withLock { _ in
            let path = url.path
            let manager = FileManager.default
            if !manager.fileExists(atPath: path) {
                guard manager.createFile(atPath: path, contents: nil) else { return }
            }
            guard let handle = try? FileHandle(forUpdating: url) else { return }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd() else { return }
            var bytes = Data(entry.line.utf8)
            if end > 0, (try? handle.seek(toOffset: end - 1)) != nil,
                (try? handle.read(upToCount: 1)) != Data("\n".utf8)
            {
                // A line a crash cut short would swallow this one, so it is ended first.
                bytes.insert(UInt8(ascii: "\n"), at: 0)
            }
            guard (try? handle.write(contentsOf: bytes)) != nil else { return }
            try? handle.seek(toOffset: 0)
            let oldest = (try? handle.read(upToCount: 32)).flatMap(UsageLedgerEntry.firstDate(in:))
            guard oldest.map({ $0 < entry.at.addingTimeInterval(-retention - trimSlack) }) ?? true
            else { return }
            trim(url, since: entry.at.addingTimeInterval(-retention))
        }
    }

    /// No file is no usage; a period's lines are decoded and the rest only have their date read.
    nonisolated static func entries(at url: URL, in interval: DateInterval) throws -> [UsageLedgerEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return UsageLedgerEntry.entries(in: data, during: interval)
    }

    private static func trim(_ url: URL, since cutoff: Date) {
        guard let data = try? Data(contentsOf: url) else { return }
        try? UsageLedgerEntry.kept(data, since: cutoff).write(to: url, options: .atomic)
    }
}
