import Foundation
import Observation

/// The note picker's list while it is shown; every read runs off-main and dies with the picker.
@MainActor
@Observable
final class NotePickerModel {
    private(set) var rows: [NoteSummary] = []
    private(set) var isLoading = true
    private(set) var isSearching = false
    var selection = 0
    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }

    private let repository: NotesRepository
    @ObservationIgnored private var all: [NoteSummary] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// The Notes switcher's cap: a picker is for finding one note, not browsing thousands.
    private static let limit = 200

    init(repository: NotesRepository) {
        self.repository = repository
    }

    isolated deinit {
        searchTask?.cancel()
    }

    func load(after flush: () async -> Void) async {
        await flush()
        let repository = repository
        let listed = await Task.detached(priority: .userInitiated) {
            (try? repository.list()) ?? []
        }.value
        guard !Task.isCancelled else { return }
        all = listed
        isLoading = false
        if query.isEmpty { show(Array(listed.prefix(Self.limit))) } else { scheduleSearch() }
    }

    func move(by offset: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(selection + offset, 0), rows.count - 1)
    }

    var selected: NoteSummary? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        generation &+= 1
    }

    private func scheduleSearch() {
        cancel()
        let search = NoteSearch.Query(query)
        guard !search.isEmpty else {
            isSearching = false
            show(Array(all.prefix(Self.limit)))
            return
        }
        guard !isLoading else { return }
        isSearching = true
        rows = []
        let generation = generation
        let repository = repository
        let summaries = all
        let limit = Self.limit
        searchTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(120))) != nil else { return }
            let worker = Task.detached(priority: .userInitiated) {
                repository.search(search, summaries: summaries, limit: limit).map(\.summary)
            }
            // A superseded query stops the body reads too, not only the result.
            let found = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            isSearching = false
            show(found)
        }
    }

    private func show(_ summaries: [NoteSummary]) {
        rows = summaries
        selection = 0
    }
}
