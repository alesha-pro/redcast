import AppKit

/// The one Agents menu-bar item, fed by background runs and by Agent Sessions' live status.
extension AgentCoordinator {
    /// Either source changed; with nothing to show the item goes, so an idle Mac holds none.
    func refreshMenuBar() {
        let sessions = core.agentSessionsCoordinator.menuBarIndicator
        let indicator = (runs?.indicator ?? .hidden).merged(with: sessions)
        guard indicator != .hidden else {
            // An open menu keeps its item; closing it comes back here.
            guard menuBarItem?.isMenuOpen != true else { return }
            menuBarItem?.remove()
            menuBarItem = nil
            return
        }
        let item = menuBarItem ?? makeMenuBarItem()
        menuBarItem = item
        item.show(indicator)
    }

    var isMenuBarOpen: Bool { menuBarItem?.isMenuOpen == true }

    private func makeMenuBarItem() -> AgentsStatusItem {
        AgentsStatusItem(
            actions: AgentsStatusItem.Actions(
                runs: { [weak self] in self?.runs?.runs ?? [] },
                sessions: { [weak self] in self?.core.agentSessionsCoordinator.menuBarRows },
                openRun: { [weak self] in self?.backgroundRuns?.open($0) },
                stopRun: { [weak self] in self?.backgroundRuns?.stop($0) },
                jumpToSession: { [weak self] in self?.core.agentSessionsCoordinator.jump(toSession: $0) },
                searchSessions: { [weak self] in self?.core.agentSessionsCoordinator.show() },
                clearFinishedSessions: { [weak self] in self?.core.agentSessionsCoordinator.clearFinished() },
                settings: { [weak self] in self?.showAgentSettings() },
                viewed: { [weak self] in
                    self?.backgroundRuns?.markFinishedSeen()
                    self?.core.agentSessionsCoordinator.markFinishedSeen()
                    self?.refreshMenuBar()
                },
                closed: { [weak self] in
                    // After the chosen row's action, which AppKit sends once the menu has closed.
                    Task { @MainActor in
                        self?.refreshMenuBar()
                        self?.backgroundRuns?.releaseIfIdle()
                    }
                }))
    }
}
