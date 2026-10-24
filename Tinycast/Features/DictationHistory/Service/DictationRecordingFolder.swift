import Foundation
import Synchronization

/// Failed dictations' recordings, one WAV each, trimmed whenever one is written; never backed up.
enum DictationRecordingFolder {
    static let url = AppPaths.applicationSupport().appending(
        path: "dictation-failed-audio", directoryHint: .isDirectory)

    private static let writing = Mutex(())

    /// Best effort, like the history's own line; `historyCutoff` is Keep history's oldest date.
    nonisolated static func keep(
        _ wav: Data, as recording: DictationKeptRecording, historyCutoff: Date?, in folder: URL = url
    ) {
        writing.withLock { _ in
            let manager = FileManager.default
            guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
            else { return }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = folder
            try? excluded.setResourceValues(values)
            try? wav.write(to: folder.appending(path: recording.fileName), options: .atomic)
            let cutoff = DictationKeptRecording.cutoff(now: recording.date, history: historyCutoff)
            trimLocked(folder, cutoff: cutoff)
        }
    }

    /// The entries whose recording is still on disk, for the screen's Retry.
    nonisolated static func kept(now: Date, historyCutoff: Date?, in folder: URL = url) -> Set<UUID> {
        writing.withLock { _ in
            let cutoff = DictationKeptRecording.cutoff(now: now, history: historyCutoff)
            return Set(recordings(in: folder).filter { $0.date >= cutoff }.map(\.id))
        }
    }

    nonisolated static func samples(for id: UUID, sampleRate: Int, in folder: URL = url) -> [Float]? {
        writing.withLock { _ in
            guard let recording = recordings(in: folder).first(where: { $0.id == id }),
                let data = try? Data(contentsOf: folder.appending(path: recording.fileName))
            else { return nil }
            return DictationKeptRecording.samples(fromWAV: data, sampleRate: sampleRate)
        }
    }

    nonisolated static func delete(_ ids: Set<UUID>, in folder: URL = url) {
        guard !ids.isEmpty else { return }
        writing.withLock { _ in
            remove(recordings(in: folder).filter { ids.contains($0.id) }, from: folder)
        }
    }

    /// A shorter Keep history applies to the recordings at once; Off removes them all.
    nonisolated static func trim(now: Date, historyCutoff: Date?, in folder: URL = url) {
        writing.withLock { _ in
            trimLocked(folder, cutoff: DictationKeptRecording.cutoff(now: now, history: historyCutoff))
        }
    }

    nonisolated static func clear(in folder: URL = url) {
        writing.withLock { _ in try? FileManager.default.removeItem(at: folder) }
    }

    private static func trimLocked(_ folder: URL, cutoff: Date) {
        let all = recordings(in: folder)
        let expired = DictationKeptRecording.expired(all, cutoff: cutoff)
        remove(all.filter { expired.contains($0.id) }, from: folder)
    }

    private static func recordings(in folder: URL) -> [DictationKeptRecording] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name in
            let size = try? folder.appending(path: name).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return DictationKeptRecording(fileName: name, bytes: size ?? 0)
        }
    }

    /// A folder left with nothing of ours in it is removed, so no recording reads as no folder.
    private static func remove(_ recordings: [DictationKeptRecording], from folder: URL) {
        let manager = FileManager.default
        for recording in recordings {
            try? manager.removeItem(at: folder.appending(path: recording.fileName))
        }
        if let left = try? manager.contentsOfDirectory(atPath: folder.path),
            !left.contains(where: { DictationKeptRecording(fileName: $0, bytes: 0) != nil })
        {
            try? manager.removeItem(at: folder)
        }
    }
}
