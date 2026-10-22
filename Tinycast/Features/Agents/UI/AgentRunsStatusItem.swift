import AppKit

/// The transient menu-bar item for unattended runs; it exists only while one is worth showing.
@MainActor
final class AgentRunsStatusItem: NSObject, NSMenuDelegate {
    struct Actions {
        let open: (UUID) -> Void
        let stop: (UUID) -> Void
        let settings: () -> Void
        /// The menu opened: every finished run counts as seen.
        let viewed: () -> Void
        /// The menu closed: the owner may remove the item.
        let closed: () -> Void
    }

    private static let maxRows = 10

    private let item: NSStatusItem
    private let menu = NSMenu()
    private let actions: Actions
    private var runs: [AgentRun] = []
    private(set) var isMenuOpen = false

    init(actions: Actions) {
        self.actions = actions
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.autosaveName = "TinycastAgentRuns"
        item.button?.imagePosition = .imageLeading
        item.button?.setAccessibilityLabel(String(localized: "Agent runs"))
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
    }

    /// No symbol effect or animation: an item that never redraws costs nothing while a run works.
    func show(_ indicator: AgentRunLedger.Indicator, runs: [AgentRun]) {
        self.runs = runs
        let symbol: String
        var count = ""
        switch indicator {
        case .hidden, .done: symbol = "checkmark.circle"
        case .waiting: symbol = "exclamationmark.circle"
        case .failed: symbol = "xmark.circle"
        case .running(let active):
            symbol = "ellipsis.circle"
            if active > 1 { count = "\(active)" }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.title = count
        item.length = count.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
    }

    func remove() {
        menu.cancelTracking()
        menu.delegate = nil
        NSStatusBar.system.removeStatusItem(item)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        for run in runs.prefix(Self.maxRows) {
            let row = NSMenuItem(
                title: "\(run.agentName) — \(run.title)", action: #selector(open(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = run.id
            row.subtitle = subtitle(for: run, now: now)
            row.image = NSImage(systemSymbolName: run.symbol, accessibilityDescription: nil)
            menu.addItem(row)
            guard run.isActive else { continue }
            let stop = NSMenuItem(
                title: String(localized: "Stop \(run.agentName)"), action: #selector(stop(_:)),
                keyEquivalent: "")
            stop.target = self
            stop.representedObject = run.id
            stop.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
            stop.isAlternate = true
            stop.keyEquivalentModifierMask = .option
            menu.addItem(stop)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(
            title: String(localized: "Agent Settings…"), action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        actions.viewed()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        actions.closed()
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        actions.open(id)
    }

    @objc private func stop(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        actions.stop(id)
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
            case .failed(let reason): String(localized: "Failed: \(reason)")
            }
        var parts = [state]
        if run.declined > 0 { parts.append(String(localized: "\(run.declined) requests declined")) }
        if let problem = run.problem { parts.append(problem) }
        return parts.joined(separator: " · ")
    }
}
