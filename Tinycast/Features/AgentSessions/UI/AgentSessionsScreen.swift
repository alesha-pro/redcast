import SwiftUI

/// Search Agent Sessions: every Claude Code, Codex and Tinycast session, previewed and resumable.
struct AgentSessionsScreen: PaletteScreen {
    enum Row: Identifiable, Equatable {
        case session(AgentSession)
        case searchTranscripts(String)

        var id: String {
            switch self {
            case .session(let session): session.id
            case .searchTranscripts: "search-transcripts"
            }
        }
    }

    let coordinator: AgentSessionsCoordinator
    let index: AgentSessionIndex
    let chatHistory: ChatHistoryStore
    let chat: AIChatState
    let vm: PaletteState
    let metrics: InterfaceMetrics
    let openActions: () -> Void
    let rows: [Row]
    /// The Show section stays reachable when a filter hides every row.
    let actsWithoutRows = true

    init(
        coordinator: AgentSessionsCoordinator, index: AgentSessionIndex, chatHistory: ChatHistoryStore,
        chat: AIChatState, vm: PaletteState, metrics: InterfaceMetrics, openActions: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.index = index
        self.chatHistory = chatHistory
        self.chat = chat
        self.vm = vm
        self.metrics = metrics
        self.openActions = openActions
        rows = Self.rows(index: index, query: vm.query)
    }

    private static func rows(index: AgentSessionIndex, query: String) -> [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let search = index.transcriptSearch, search.query == trimmed {
            return search.hits.compactMap { hit in
                index.session(id: hit.source.rawValue + ":" + hit.sessionID).map(Row.session)
            }
        }
        var rows = index.rows(for: query).map(Row.session)
        if trimmed.count >= AgentTranscriptSearch.minimumQuery { rows.append(.searchTranscripts(trimmed)) }
        return rows
    }

    private func row(at selection: Int) -> Row? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    private func session(at selection: Int) -> AgentSession? {
        guard case .session(let session)? = row(at: selection) else { return nil }
        return session
    }

    var primaryActionTitle: String {
        switch row(at: vm.selection) {
        case .session(let session)?: coordinator.primaryTitle(for: session)
        case .searchTranscripts?: String(localized: "Search")
        case nil: String(localized: "Search")
        }
    }

    func hasPrimaryAction(at selection: Int) -> Bool { row(at: selection) != nil }

    func actions(at selection: Int) -> PopoverMenuContent? {
        AgentSessionsActionsMenu.content(session: session(at: selection), coordinator: coordinator, index: index)
    }

    func activate(at selection: Int) {
        switch row(at: selection) {
        case .session(let session)?: coordinator.activate(session)
        case .searchTranscripts(let query)?: index.searchTranscripts(query)
        case nil: break
        }
    }

    func secondary(at selection: Int) -> Bool {
        guard let session = session(at: selection) else { return false }
        if session.source == .tinycast {
            coordinator.openChat(session, inQuickAI: true)
        } else {
            coordinator.copyResumeCommand(session)
        }
        return true
    }

    func tertiary(at selection: Int) -> Bool {
        guard let session = session(at: selection), session.source != .tinycast else { return false }
        coordinator.resume(session, action: .fork)
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        if shortcut == .restart {
            index.refresh()
            return true
        }
        guard let session = session(at: selection) else { return false }
        switch shortcut {
        case .openInApp:
            guard coordinator.canOpenInApp(session) else { return false }
            coordinator.openInApp(session)
        case .showInFinder:
            guard session.directory != nil else { return false }
            coordinator.showFolder(session)
        case .copyPath:
            guard session.directory != nil else { return false }
            coordinator.copyFolderPath(session)
        case .copyName:
            guard session.source != .tinycast else { return false }
            coordinator.copySessionID(session)
        case .continueInChat:
            guard session.source == .tinycast else { return false }
            coordinator.openChat(session, inQuickAI: false)
        default:
            return false
        }
        return true
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(
            AgentSessionsView(
                rows: rows, selection: selection, scroll: scroll, coordinator: coordinator, index: index,
                chatHistory: chatHistory, chat: chat, vm: vm, metrics: metrics, openActions: openActions,
                activate: activate(at:)))
    }
}

/// The screen's one view, so opening and leaving it is what loads and frees the index.
private struct AgentSessionsView: View {
    let rows: [AgentSessionsScreen.Row]
    let selection: Int
    let scroll: ScrollIntent
    let coordinator: AgentSessionsCoordinator
    let index: AgentSessionIndex
    let chatHistory: ChatHistoryStore
    let chat: AIChatState
    let vm: PaletteState
    let metrics: InterfaceMetrics
    let openActions: () -> Void
    let activate: (Int) -> Void

    private var selected: AgentSessionsScreen.Row? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    /// A container, so switching between the list and an empty state never reads as leaving.
    var body: some View {
        ZStack { content }
            .onAppear { coordinator.screenAppeared() }
            .onDisappear { coordinator.screenDisappeared() }
            .onChange(of: vm.query) {
                if index.transcriptSearch != nil { index.cancelTranscriptSearch() }
            }
    }

    @ViewBuilder private var content: some View {
        if rows.isEmpty, index.phase == .ready, index.transcriptSearch == nil {
            EmptyResults(
                text: index.sessions.isEmpty
                    ? String(localized: "No agent sessions yet") : String(localized: "No matching sessions"),
                detail: unreadableLine)
        } else {
            HStack(spacing: 0) {
                AgentSessionsList(
                    rows: rows, selectedID: selected?.id, scroll: scroll, index: index,
                    query: vm.query,
                    onSelect: { row in vm.selection = rows.firstIndex(of: row) ?? 0 },
                    onActivate: { row in
                        vm.selection = rows.firstIndex(of: row) ?? 0
                        activate(vm.selection)
                    },
                    onActions: { row in
                        vm.selection = rows.firstIndex(of: row) ?? 0
                        openActions()
                    }
                )
                .frame(width: metrics.size.clipboardListWidth)
                Rectangle().fill(Theme.Colors.separator).frame(width: Theme.Size.hairline)
                preview
            }
        }
    }

    @ViewBuilder private var preview: some View {
        switch selected {
        case .session(let session)? where session.source == .tinycast:
            ChatHistoryPreview(history: chatHistory, chat: chat, conversationID: UUID(uuidString: session.sessionID))
        case .session(let session)?:
            AgentSessionPreview(
                session: session, live: index.live[session.id], locations: index.locations,
                command: coordinator.resumeCommand(session, action: .resume))
        default:
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var unreadableLine: String? {
        index.unreadable.isEmpty ? nil : AgentSessionsList.unreadableText(index.unreadable)
    }
}

@MainActor
enum AgentSessionsActionsMenu {
    static func content(
        session: AgentSession?, coordinator: AgentSessionsCoordinator, index: AgentSessionIndex
    ) -> PopoverMenuContent {
        var items = session.map { sessionItems($0, coordinator: coordinator) } ?? []
        items.append(
            PopoverMenuItem(
                title: String(localized: "Refresh"), systemImage: "arrow.clockwise", startsSection: !items.isEmpty,
                shortcut: "⌘R"
            ) {
                index.refresh()
            })
        items += filterItems(index: index)
        return PopoverMenuContent(header: session.map { AgentSessionsList.title(of: $0) }, items: items)
    }

    private static func sessionItems(_ session: AgentSession, coordinator: AgentSessionsCoordinator)
        -> [PopoverMenuItem]
    {
        guard session.source != .tinycast else { return tinycastItems(session, coordinator: coordinator) }
        let terminal = coordinator.terminal(for: session).displayName
        var items: [PopoverMenuItem] = []
        if coordinator.primaryAction(for: session) == .jump {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Jump to Session"), systemImage: "arrow.up.forward.app", shortcut: "↵"
                ) {
                    coordinator.activate(session)
                })
        }
        items.append(
            PopoverMenuItem(
                title: String(localized: "Resume in \(terminal)"), systemImage: "terminal",
                shortcut: items.isEmpty ? "↵" : nil
            ) {
                coordinator.resume(session, action: .resume)
            })
        items += [
            PopoverMenuItem(
                title: String(localized: "Copy Resume Command"), systemImage: "doc.on.doc", shortcut: "⌘↵"
            ) {
                coordinator.copyResumeCommand(session)
            },
            PopoverMenuItem(
                title: String(localized: "Fork in \(terminal)"), systemImage: "arrow.triangle.branch",
                shortcut: "⌃⌘↵"
            ) {
                coordinator.resume(session, action: .fork)
            }
        ]
        if coordinator.canOpenInApp(session) {
            let title =
                session.source == .claude ? String(localized: "Open in Claude") : String(localized: "Open in Codex")
            items.append(
                PopoverMenuItem(title: title, systemImage: "arrow.up.right.square", shortcut: "⌘O") {
                    coordinator.openInApp(session)
                })
        }
        items += folderItems(session, coordinator: coordinator)
        items.append(
            PopoverMenuItem(title: String(localized: "Copy Session ID"), systemImage: "number", shortcut: "⌥⌘C") {
                coordinator.copySessionID(session)
            })
        if session.directory != nil {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Open Folder in \(terminal)"), systemImage: "folder.badge.gearshape"
                ) {
                    coordinator.resume(session, action: .openFolder)
                })
        }
        return items
    }

    private static func tinycastItems(_ session: AgentSession, coordinator: AgentSessionsCoordinator)
        -> [PopoverMenuItem]
    {
        [
            PopoverMenuItem(title: String(localized: "Open Chat"), systemImage: "bubble.left", shortcut: "↵") {
                coordinator.openChat(session, inQuickAI: false)
            },
            PopoverMenuItem(title: String(localized: "Open in Quick AI"), systemImage: "sparkles", shortcut: "⌘↵") {
                coordinator.openChat(session, inQuickAI: true)
            },
            PopoverMenuItem(
                title: String(localized: "Continue in AI Chat"), systemImage: "bubble.left.and.bubble.right",
                shortcut: "⌘J"
            ) {
                coordinator.openChat(session, inQuickAI: false)
            }
        ] + folderItems(session, coordinator: coordinator)
    }

    private static func folderItems(_ session: AgentSession, coordinator: AgentSessionsCoordinator)
        -> [PopoverMenuItem]
    {
        guard session.directory != nil else { return [] }
        return [
            PopoverMenuItem(title: String(localized: "Show Folder in Finder"), systemImage: "folder", shortcut: "⌘F") {
                coordinator.showFolder(session)
            },
            PopoverMenuItem(
                title: String(localized: "Copy Folder Path"), systemImage: "doc.on.clipboard", shortcut: "⌃⌘C"
            ) {
                coordinator.copyFolderPath(session)
            }
        ]
    }

    private static func filterItems(index: AgentSessionIndex) -> [PopoverMenuItem] {
        let filter = index.filter
        let sources: [(AgentSource?, String)] = [
            (nil, String(localized: "All Sources")), (.claude, AgentSource.claude.productName),
            (.codex, AgentSource.codex.productName), (.tinycast, AgentSource.tinycast.productName)
        ]
        var items = sources.enumerated().map { position, entry in
            PopoverMenuItem(
                title: entry.1, icon: filter.source == entry.0 ? .symbol("checkmark") : .blank,
                sectionTitle: position == 0 ? String(localized: "Show") : nil, startsSection: position == 0
            ) {
                index.filter.source = entry.0
            }
        }
        items.append(
            PopoverMenuItem(
                title: String(localized: "Show Automated Runs"),
                icon: filter.showsAutomated ? .symbol("checkmark") : .blank, startsSection: true
            ) {
                index.filter.showsAutomated.toggle()
            })
        items.append(
            PopoverMenuItem(
                title: String(localized: "Include Archived Codex Threads"),
                icon: filter.showsArchived ? .symbol("checkmark") : .blank
            ) {
                index.filter.showsArchived.toggle()
            })
        return items
    }
}
