import Foundation
import Observation
import os

/// Every source's sessions while the screen is open; empty again from `close()` on.
@MainActor
@Observable
final class AgentSessionIndex {
    enum Phase: Equatable { case idle, loading(done: Int, total: Int), ready }

    struct TranscriptSearchState: Equatable {
        let id = UUID()
        let query: String
        var hits: [AgentTranscriptSearch.Hit] = []
        var done = 0
        var total = 0
        var isFinished = false
    }

    private(set) var sessions: [AgentSession] = []
    private(set) var phase: Phase = .idle
    private(set) var unreadable: Set<AgentSource> = []
    /// Keyed by `AgentSession.id`: the probe's entries with the hooks' reports over them.
    private(set) var live: [String: AgentLiveEntry] = [:]
    private(set) var transcriptSearch: TranscriptSearchState?
    var filter = AgentSessionFilter() {
        didSet {
            guard filter != oldValue else { return }
            memo = nil
            if filter.showsArchived != oldValue.showsArchived, phase != .idle { reloadCodex() }
        }
    }

    @ObservationIgnored private var keyed: [String: (session: AgentSession, keys: AgentSessionSearchKeys)] = [:]
    @ObservationIgnored private var entries: [(AgentSession, AgentSessionSearchKeys)] = []
    @ObservationIgnored private var bySource: [AgentSource: [AgentSession]] = [:]
    @ObservationIgnored private var probed: [String: AgentLiveEntry] = [:]
    @ObservationIgnored private var reported: [String: AgentLiveEntry] = [:]
    @ObservationIgnored private var memo: (query: String, revision: Int, rows: [AgentSession])?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var codexLoading: Task<Void, Never>?
    @ObservationIgnored private var searching: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var revision = 0

    private let chatHistory: ChatHistoryStore
    private let agentStore: AgentStore
    private let home: URL
    private let cacheURL: URL
    private let claudeExecutable: () async -> URL?
    private static let log = Logger(subsystem: "com.tinycast", category: "AgentSessions")

    init(
        chatHistory: ChatHistoryStore, agentStore: AgentStore, home: URL, cacheURL: URL,
        claudeExecutable: @escaping () async -> URL?
    ) {
        self.chatHistory = chatHistory
        self.agentStore = agentStore
        self.home = home
        self.cacheURL = cacheURL
        self.claudeExecutable = claudeExecutable
    }

    var claudeRoot: URL { home.appending(path: ".claude/projects", directoryHint: .isDirectory) }
    var codexState: URL { home.appending(path: ".codex/state_5.sqlite", directoryHint: .notDirectory) }
    var codexHistory: URL { home.appending(path: ".codex/thread_history_1.sqlite", directoryHint: .notDirectory) }

    /// Memoised on (query, revision, filter): the palette rebuilds the screen many times a render.
    func rows(for query: String) -> [AgentSession] {
        _ = sessions
        _ = live
        let filter = self.filter
        if let memo, memo.query == query, memo.revision == revision { return memo.rows }
        let rows = AgentSessionQuery.rank(entries, query: query, filter: filter, live: live)
        memo = (query, revision, rows)
        return rows
    }

    func session(id: AgentSession.ID) -> AgentSession? {
        keyed[id]?.session
    }

    /// A preserved re-summon finds the index loaded and keeps it as it is.
    func open() {
        guard phase == .idle else { return }
        load()
    }

    func refresh() {
        guard phase != .idle else { return open() }
        load()
    }

    func close() {
        loading?.cancel()
        codexLoading?.cancel()
        loading = nil
        codexLoading = nil
        cancelTranscriptSearch()
        generation += 1
        phase = .idle
        sessions = []
        live = [:]
        unreadable = []
        filter = AgentSessionFilter()
        keyed = [:]
        entries = []
        bySource = [:]
        probed = [:]
        reported = [:]
        memo = nil
    }

    /// The hooks' view of running agents, pushed by the coordinator while the screen is open.
    func applyReported(_ activities: [AgentActivity]) {
        guard phase != .idle else { return }
        reported = Dictionary(
            activities.map { activity in
                (
                    activity.id,
                    AgentLiveEntry(
                        sessionID: activity.sessionID, status: activity.status, pid: nil, backgroundID: nil,
                        directory: activity.directory, startedAt: activity.updatedAt,
                        hostBundleID: activity.hostBundleID, tty: activity.tty)
                )
            }, uniquingKeysWith: { first, _ in first })
        mergeLive()
    }

    func searchTranscripts(_ query: String) {
        cancelTranscriptSearch()
        guard query.count >= AgentTranscriptSearch.minimumQuery else { return }
        let state = TranscriptSearchState(query: query)
        transcriptSearch = state
        let stream = AgentTranscriptSearch.run(
            query: query, sessions: sessions.filter(filter.admits), codexHistory: codexHistory,
            progress: { [weak self] done, total in
                Task { @MainActor in
                    guard let self, self.transcriptSearch?.id == state.id else { return }
                    self.transcriptSearch?.done = done
                    self.transcriptSearch?.total = total
                }
            })
        searching = Task { [weak self] in
            for await hit in stream {
                guard let self, self.transcriptSearch?.id == state.id else { return }
                self.transcriptSearch?.hits.append(hit)
            }
            guard let self, self.transcriptSearch?.id == state.id else { return }
            self.transcriptSearch?.isFinished = true
        }
    }

    func cancelTranscriptSearch() {
        searching?.cancel()
        searching = nil
        if transcriptSearch != nil { transcriptSearch = nil }
    }

    // MARK: - Loading

    private func load() {
        loading?.cancel()
        codexLoading?.cancel()
        generation += 1
        let generation = generation
        phase = .loading(done: 0, total: 0)
        unreadable = []
        let acp = Set(agentStore.acpSessions.values)
        publish(.tinycast, tinycastSessions())
        let includeArchived = filter.showsArchived
        loading = Task { [weak self] in
            await self?.loadCodex(generation, includeArchived: includeArchived, acp: acp)
            await self?.loadClaude(generation, acp: acp)
            await self?.loadLive(generation)
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.phase = .ready
        }
    }

    private func reloadCodex() {
        codexLoading?.cancel()
        let generation = generation
        let acp = Set(agentStore.acpSessions.values)
        let includeArchived = filter.showsArchived
        codexLoading = Task { [weak self] in
            await self?.loadCodex(generation, includeArchived: includeArchived, acp: acp)
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation && !Task.isCancelled
    }

    private func loadCodex(_ generation: Int, includeArchived: Bool, acp: Set<String>) async {
        let result = await AgentSessionsScanner.codexThreads(database: codexState, includeArchived: includeArchived)
        guard isCurrent(generation) else { return }
        switch result {
        case .success(let threads):
            unreadable.remove(.codex)
            publish(.codex, threads.filter { !acp.contains($0.sessionID) })
        case .failure(.missing):
            publish(.codex, [])
        case .failure(let failure):
            Self.log.error("Codex history unreadable: \(String(describing: failure), privacy: .public)")
            unreadable.insert(.codex)
            publish(.codex, [])
        }
    }

    private func loadClaude(_ generation: Int, acp: Set<String>) async {
        let root = claudeRoot
        let rootPath = root.path
        let cache = await AgentSessionsScanner.loadCache(cacheURL, root: rootPath)
        let listing = await AgentSessionsScanner.listClaude(root: root)
        guard isCurrent(generation) else { return }
        let cached = Dictionary(
            (cache?.entries ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let plan = ClaudeRescanPolicy.plan(cached: cached, listing: listing)
        var found: [String: ClaudeIndexEntry] = [:]
        for (item, step) in plan.steps where step == .reuse { found[item.path] = cached[item.path] }
        publishClaude(found, root: rootPath, acp: acp)
        let work = plan.steps.filter { $0.1 != .reuse }
        var done = 0
        while done < work.count {
            phase = .loading(done: done, total: work.count)
            let batch = Array(work[done..<min(done + AgentSessionsScanner.batchSize, work.count)])
            let scanned = await AgentSessionsScanner.scan(batch, cached: cached, root: root)
            guard isCurrent(generation) else { return }
            for entry in scanned { found[entry.path] = entry }
            done += batch.count
            publishClaude(found, root: rootPath, acp: acp)
        }
        phase = .loading(done: work.count, total: work.count)
        guard !work.isEmpty || !plan.dropped.isEmpty else { return }
        let file = ClaudeIndexFile(projectsRoot: rootPath, entries: found.values.sorted { $0.path < $1.path })
        await AgentSessionsScanner.saveCache(file, to: cacheURL)
    }

    private func loadLive(_ generation: Int) async {
        guard bySource[.claude]?.isEmpty == false, let executable = await claudeExecutable() else { return }
        let entries = await AgentProcessHost.resolving(
            await ClaudeLiveSessionsProbe.run(executable: executable, home: home))
        guard isCurrent(generation) else { return }
        probed = Dictionary(
            entries.map { ("claude:" + $0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        mergeLive()
    }

    // MARK: - Publishing

    private func tinycastSessions() -> [AgentSession] {
        chatHistory.conversations.map { conversation in
            let agent = agentStore.agent(forChat: conversation.id)
            let origin: AgentSessionTitleOrigin =
                conversation.customTitle != nil
                ? .named : conversation.generatedTitle != nil ? .generated : .prompt
            return AgentSession(
                source: .tinycast, sessionID: conversation.id.uuidString, title: conversation.displayTitle,
                titleOrigin: origin, firstPrompt: conversation.preview, lastPrompt: conversation.preview,
                directory: agent?.directory, createdAt: conversation.createdAt, updatedAt: conversation.updatedAt,
                host: .tinycast, agentName: agent?.name)
        }
    }

    private func publishClaude(_ found: [String: ClaudeIndexEntry], root: String, acp: Set<String>) {
        let sessions = found.values.compactMap { ClaudeRescanPolicy.session(from: $0, root: root) }
        publish(.claude, sessions.filter { !acp.contains($0.sessionID) })
    }

    /// Keys are folded once per session and kept until that session itself changes.
    private func publish(_ source: AgentSource, _ list: [AgentSession]) {
        bySource[source] = list
        var seen: Set<String> = []
        let merged = bySource.values.joined().sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.id).inserted }
        var next: [String: (session: AgentSession, keys: AgentSessionSearchKeys)] = [:]
        next.reserveCapacity(merged.count)
        for session in merged {
            if let known = keyed[session.id], known.session == session {
                next[session.id] = known
            } else {
                next[session.id] = (session, AgentSessionSearchKeys(session))
            }
        }
        keyed = next
        entries = merged.compactMap { next[$0.id].map { ($0.session, $0.keys) } }
        sessions = merged
        revision += 1
        memo = nil
    }

    private func mergeLive() {
        let merged = probed.merging(reported) { _, hook in hook }
        guard merged != live else { return }
        live = merged
        revision += 1
        memo = nil
    }
}
