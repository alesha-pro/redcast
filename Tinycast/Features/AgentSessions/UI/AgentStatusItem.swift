import AppKit

/// The opt-in menu-bar list of agents that need attention; rows are built only as it opens.
@MainActor
final class AgentStatusItem: NSObject, NSMenuDelegate {
    private let status: NSStatusItem
    private let menu = NSMenu()
    private let rows: () -> [AgentActivity]
    private let onOpen: () -> Void
    private let onClose: () -> Void
    private let onSelect: (AgentActivity) -> Void
    private let onSearch: () -> Void
    private let onClear: () -> Void
    private var shown: [AgentActivity] = []

    init(
        rows: @escaping () -> [AgentActivity], onOpen: @escaping () -> Void, onClose: @escaping () -> Void,
        onSelect: @escaping (AgentActivity) -> Void, onSearch: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) {
        self.rows = rows
        self.onOpen = onOpen
        self.onClose = onClose
        self.onSelect = onSelect
        self.onSearch = onSearch
        self.onClear = onClear
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        status.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        status.button?.imagePosition = .imageLeading
        status.button?.setAccessibilityLabel(CommandID.jumpToAgent.name)
        menu.autoenablesItems = false
        menu.delegate = self
        status.menu = menu
    }

    /// The waiting count is the button's title; nothing else is drawn while the menu is closed.
    func update(waiting: Int) {
        status.button?.title = waiting > 0 ? " \(waiting)" : ""
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(status)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        shown = rows()
        for (index, activity) in shown.enumerated() {
            let item = NSMenuItem(title: Self.title(of: activity), action: #selector(select(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        if !shown.isEmpty { menu.addItem(.separator()) }
        let search = NSMenuItem(
            title: CommandID.searchAgentSessions.name, action: #selector(search), keyEquivalent: "")
        search.target = self
        menu.addItem(search)
        let clear = NSMenuItem(title: String(localized: "Clear Finished"), action: #selector(clear), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    func menuWillOpen(_ menu: NSMenu) {
        onOpen()
    }

    func menuDidClose(_ menu: NSMenu) {
        onClose()
    }

    /// Absolute times, so nothing on an open menu goes stale.
    private static func title(of activity: AgentActivity) -> String {
        let name = activity.title ?? activity.agent.productName
        let folder = activity.directory.map { ($0 as NSString).lastPathComponent } ?? activity.agent.productName
        let time = activity.updatedAt.formatted(date: .omitted, time: .shortened)
        return "\(symbol(activity.status)) \(name) — \(folder) · \(AgentSessionsList.chipTitle(activity.status)) · \(time)"
    }

    private static func symbol(_ status: AgentLiveStatus) -> String {
        switch status {
        case .waiting: "◉"
        case .working: "◌"
        default: "○"
        }
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard shown.indices.contains(sender.tag) else { return }
        onSelect(shown[sender.tag])
    }

    @objc private func search() {
        onSearch()
    }

    @objc private func clear() {
        onClear()
    }
}
