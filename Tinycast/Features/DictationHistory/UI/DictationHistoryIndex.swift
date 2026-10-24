import Foundation
import Observation

/// What a screen opens on: the entries, newest first, and which failed ones kept their recording.
struct DictationHistorySnapshot: Sendable {
    var entries: [DictationHistoryEntry] = []
    var recordings: Set<UUID> = []
}

/// The history while its screen is open, newest first; empty again from `close()` on.
@MainActor
@Observable
final class DictationHistoryIndex {
    enum Phase: Equatable { case idle, loading, ready }

    private(set) var entries: [DictationHistoryEntry] = []
    private(set) var phase: Phase = .idle
    /// Failed entries whose recording is on disk, so Retry is offered.
    private(set) var recordings: Set<UUID> = []
    var retries = DictationRetryState()

    @ObservationIgnored private var keys: [DictationHistorySearchKey] = []
    @ObservationIgnored private var memo: (query: String, revision: Int, rows: [DictationHistoryEntry])?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// Memoised on (query, revision): the palette rebuilds the screen many times a render.
    func rows(for query: String) -> [DictationHistoryEntry] {
        _ = entries
        if let memo, memo.query == query, memo.revision == revision { return memo.rows }
        let rows = DictationHistoryQuery.filter(entries, keys: keys, query: query)
        memo = (query, revision, rows)
        return rows
    }

    func entry(id: DictationHistoryEntry.ID) -> DictationHistoryEntry? {
        entries.first { $0.id == id }
    }

    /// A preserved re-summon finds the history loaded and keeps it.
    func open(_ load: @escaping @Sendable () async -> DictationHistorySnapshot) {
        guard phase == .idle else { return }
        reload(load)
    }

    func reload(_ load: @escaping @Sendable () async -> DictationHistorySnapshot) {
        loading?.cancel()
        phase = .loading
        loading = Task { [weak self] in
            let loaded = await load()
            guard !Task.isCancelled, let self else { return }
            let keys = await Self.keys(for: loaded.entries)
            guard !Task.isCancelled else { return }
            replace(loaded.entries, keys: keys)
            recordings = loaded.recordings
            phase = .ready
            loading = nil
        }
    }

    /// A dictation finished while the screen is open joins it at the top.
    func insert(_ entry: DictationHistoryEntry, recorded: Bool = false) {
        guard phase == .ready else { return }
        replace([entry] + entries, keys: [DictationHistorySearchKey(entry)] + keys)
        if recorded { recordings.insert(entry.id) }
    }

    /// A retry's result, in the entry's place; a transcribed one no longer has a recording.
    func update(_ entry: DictationHistoryEntry) {
        guard let position = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var entries = entries
        var keys = keys
        entries[position] = entry
        keys[position] = DictationHistorySearchKey(entry)
        replace(entries, keys: keys)
        if !entry.isFailed { recordings.remove(entry.id) }
    }

    func remove(_ ids: Set<DictationHistoryEntry.ID>) {
        guard !ids.isEmpty else { return }
        let kept = zip(entries, keys).filter { !ids.contains($0.0.id) }
        replace(kept.map(\.0), keys: kept.map(\.1))
        recordings.subtract(ids)
        retries.cancel(ids)
    }

    func removeAll() {
        replace([], keys: [])
        forgetRecordings()
    }

    func forgetRecordings() {
        recordings = []
        retries.cancelAll()
    }

    func close() {
        loading?.cancel()
        loading = nil
        phase = .idle
        replace([], keys: [])
        forgetRecordings()
    }

    private func replace(_ entries: [DictationHistoryEntry], keys: [DictationHistorySearchKey]) {
        self.entries = entries
        self.keys = keys
        revision += 1
        memo = nil
    }

    /// Folding a few thousand transcripts is work enough to keep off the main actor.
    @concurrent
    private static func keys(for entries: [DictationHistoryEntry]) async -> [DictationHistorySearchKey] {
        entries.map(DictationHistorySearchKey.init)
    }
}
