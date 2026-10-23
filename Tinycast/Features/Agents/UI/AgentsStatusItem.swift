import AppKit

/// The one Agents menu-bar item: background runs and live sessions, there only while one shows.
@MainActor
final class AgentsStatusItem: NSObject, NSMenuDelegate {
    /// A live session's row, worded by Agent Sessions.
    struct SessionRow {
        let id: String
        let title: String
        let source: AgentSource
    }

    struct Actions {
        let runs: () -> [AgentRun]
        /// Nil while Agent Sessions' own switch keeps its sessions off the item.
        let sessions: () -> [SessionRow]?
        let openRun: (UUID) -> Void
        let stopRun: (UUID) -> Void
        let jumpToSession: (String) -> Void
        let searchSessions: () -> Void
        /// Finished background runs and finished live sessions alike.
        let clearFinished: () -> Void
        let settings: () -> Void
        /// A run's agent's colour, for its row's tile.
        let hue: (UUID) -> RaycastHue
        /// The menu opened: every finished run and session counts as seen.
        let viewed: () -> Void
        /// The menu closed: the owner may remove the item.
        let closed: () -> Void
    }

    private static let maxRows = 10

    private let item: NSStatusItem
    private let menu = NSMenu()
    private let actions: Actions
    private(set) var isMenuOpen = false

    init(actions: Actions) {
        self.actions = actions
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.autosaveName = "TinycastAgents"
        item.button?.imagePosition = .imageLeading
        item.button?.setAccessibilityLabel(String(localized: "Agents"))
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
    }

    /// No symbol effect or animation: an item that never redraws costs nothing while agents work.
    func show(_ indicator: AgentRunLedger.Indicator) {
        let symbol: String
        var count = 0
        switch indicator {
        case .hidden, .done: symbol = "checkmark.circle"
        case .failed: symbol = "xmark.circle"
        case .waiting(let waiting):
            symbol = "exclamationmark.circle"
            count = waiting
        case .running(let active):
            symbol = "ellipsis.circle"
            count = active
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.title = count > 1 ? "\(count)" : ""
        item.length = count > 1 ? NSStatusItem.variableLength : NSStatusItem.squareLength
    }

    func remove() {
        menu.cancelTracking()
        menu.delegate = nil
        NSStatusBar.system.removeStatusItem(item)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let runs = actions.runs()
        if !runs.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "Background Runs")))
            addRows(for: runs, now: Date())
        }
        let sessions = actions.sessions()
        if let sessions, !sessions.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "Agent Sessions")))
            for session in sessions {
                let sessionRow = row(session.title, #selector(jump(_:)))
                sessionRow.representedObject = session.id
                sessionRow.image = GlyphTile.menuImage(
                    symbol: session.source.tileSymbol, hue: session.source.hue)
                menu.addItem(sessionRow)
            }
        }
        menu.addItem(.separator())
        if sessions != nil {
            menu.addItem(row(CommandID.searchAgentSessions.name, #selector(searchSessions)))
        }
        if sessions != nil || runs.contains(where: { !$0.isActive }) {
            menu.addItem(row(String(localized: "Clear Finished"), #selector(clearFinished)))
        }
        menu.addItem(row(String(localized: "Agent Settings…"), #selector(openSettings)))
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        actions.viewed()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        actions.closed()
    }

    private func addRows(for runs: [AgentRun], now: Date) {
        for run in runs.prefix(Self.maxRows) {
            let runRow = row("\(run.agentName) — \(run.title)", #selector(open(_:)))
            runRow.representedObject = run.id
            runRow.subtitle = subtitle(for: run, now: now)
            runRow.image = GlyphTile.menuImage(symbol: run.symbol, hue: actions.hue(run.agentID))
            menu.addItem(runRow)
            guard run.isActive else { continue }
            let stopRow = row(String(localized: "Stop \(run.agentName)"), #selector(stop(_:)))
            stopRow.representedObject = run.id
            stopRow.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
            stopRow.isAlternate = true
            stopRow.keyEquivalentModifierMask = .option
            menu.addItem(stopRow)
        }
    }

    private func row(_ title: String, _ action: Selector) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
        row.target = self
        return row
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        actions.openRun(id)
    }

    @objc private func stop(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        actions.stopRun(id)
    }

    @objc private func jump(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        actions.jumpToSession(id)
    }

    @objc private func searchSessions() {
        actions.searchSessions()
    }

    @objc private func clearFinished() {
        actions.clearFinished()
    }

    @objc private func openSettings() {
        actions.settings()
    }

    private func subtitle(for run: AgentRun, now: Date) -> String {
        let state: String =
            switch run.state {
            case .running:
                String(localized: "Running · \(max(1, Int(now.timeIntervalSince(run.startedAt) / 60))) min")
            case .waiting: String(localized: "Waiting for your answer")
            case .done:
                String(
                    localized:
                        "Finished \((run.endedAt ?? now).formatted(date: .omitted, time: .shortened))")
            // A run the cap held back never started, so its reason alone says what happened.
            case .failed(let reason) where !run.hasChat: reason
            case .failed(let reason): String(localized: "Failed: \(reason)")
            }
        var parts = [state]
        if run.declined > 0 { parts.append(String(localized: "\(run.declined) requests declined")) }
        if let problem = run.problem { parts.append(problem) }
        return parts.joined(separator: " · ")
    }
}
