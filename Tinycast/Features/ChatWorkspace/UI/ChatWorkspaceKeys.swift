import AppKit

/// Fork: the workspace's chords in AI Chat's window, asked before upstream's own.
@MainActor
final class ChatWorkspaceKeys: NSObject {
    private let workspace: ChatWorkspaceCoordinator
    private weak var window: NSWindow?
    private weak var anchor: NSView?
    private var flagsMonitor: Any?
    private var resignToken: NotificationToken?

    init(workspace: ChatWorkspaceCoordinator) {
        self.workspace = workspace
        super.init()
    }

    isolated deinit {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        workspace.showsShortcuts = false
    }

    /// ⌘ held shows the rows' digits; only while this window is key, and never on a timer.
    func install(in window: NSWindow, anchor: NSView) {
        self.window = window
        self.anchor = anchor
        applyFloating()
        workspace.toggleFloatingWindow = { [weak self] in self?.toggleFloating() }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, let window = self.window else { return event }
            let held = event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command]
            let shows = held && event.window === window && window.isKeyWindow
            if self.workspace.showsShortcuts != shows { self.workspace.showsShortcuts = shows }
            return event
        }
        let center = NotificationCenter.default
        let observer = center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.workspace.showsShortcuts = false }
        }
        resignToken = NotificationToken(observer, center: center)
    }

    private var chat: AIChatState { workspace.chats.window }

    func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, let handled = handleComposerKey(event.keyCode) { return handled }
        let key = (ASCIIKeyboardLayout.character(for: event) ?? event.charactersIgnoringModifiers)?
            .lowercased()
        if modifiers == [.command], let key, key.count == 1, let digit = key.first,
            ChatShortcutIndex.digits.contains(digit)
        {
            return workspace.openShortcut(digit)
        }
        switch (modifiers, key) {
        case ([.control, .command], "m"):
            showMoveMenu()
        case ([.command, .shift], "i"):
            workspace.toggleSettingsSidebar?()
        case ([.command, .option], "t"):
            toggleFloating()
        default:
            return false
        }
        return true
    }

    /// ↑ and ↓ recall a question while the composer has focus; Esc gives the draft back.
    private func handleComposerKey(_ code: UInt16) -> Bool? {
        guard window?.firstResponder is ComposerTextView else { return nil }
        switch code {
        case 126: return workspace.stepRecall(-1, in: chat) ? true : nil
        case 125: return workspace.stepRecall(1, in: chat) ? true : nil
        case 53: return workspace.cancelEditing(in: chat) ? true : nil
        default: return nil
        }
    }

    /// ⌥⌘T or the Actions menu: above other apps' windows, remembered for the next window.
    func toggleFloating() {
        workspace.settings.floatsOnTop.toggle()
        applyFloating()
    }

    private func applyFloating() {
        window?.level = workspace.settings.floatsOnTop ? .floating : .normal
    }

    static let settingsItem = NSToolbarItem.Identifier("AIChatSettings")
    /// Over the settings sidebar, as an inspector's button sits in a document window.
    static let toolbarItems: [NSToolbarItem.Identifier] = [.inspectorTrackingSeparator, settingsItem]

    func toolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard identifier == Self.settingsItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
        item.label = String(localized: "Chat Settings")
        item.toolTip = String(localized: "Show or Hide Chat Settings  ⇧⌘I")
        item.target = self
        item.action = #selector(toggleSettings)
        return item
    }

    @objc private func toggleSettings() { workspace.toggleSettingsSidebar?() }

    /// The title bar's second line: the chat's model, and its agent when it has one.
    func subtitle() -> String {
        guard let summary = workspace.settingsSource?.modelSummary(for: chat) else { return "" }
        return [summary.model, summary.agent?.name].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }

    /// ⌃⌘M: the open chat's Move to Folder, hung under the toolbar's Actions button.
    private func showMoveMenu() {
        let id = chat.session.id
        guard workspace.history.conversation(id: id) != nil, let anchor else { return }
        let menu = ChatMoveNSMenu.build(chat: id, workspace: workspace)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + Theme.Spacing.xs), in: anchor)
    }
}

/// Fork: Move to Folder as an AppKit menu, for the chord and the window's Actions menu.
@MainActor
enum ChatMoveNSMenu {
    static func build(chat: UUID, workspace: ChatWorkspaceCoordinator) -> NSMenu {
        let menu = NSMenu(title: String(localized: "Move to Folder"))
        let current = workspace.workspace.folderID(of: chat)
        let recent = WorkspaceMenuItem(String(localized: "Recent"), symbol: "clock") {
            workspace.move(chat, to: nil)
        }
        recent.isEnabled = current != nil
        menu.autoenablesItems = false
        menu.addItem(recent)
        if !workspace.workspace.folders.isEmpty { menu.addItem(.separator()) }
        for folder in workspace.workspace.folders {
            let item = WorkspaceMenuItem(folder.name, symbol: nil) { workspace.move(chat, to: folder.id) }
            item.image = ChatFolderTileImage.make(symbol: folder.symbol, hue: folder.hue)
            item.state = current == folder.id ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}

/// An `NSMenuItem` that runs a closure, so a menu built per open needs no selector per row.
final class WorkspaceMenuItem: NSMenuItem {
    private let run: () -> Void

    init(
        _ title: String, symbol: String?, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
        _ run: @escaping () -> Void
    ) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func runAction() { run() }
}

/// Fork: the window's ⌘K rows the workspace adds: branch, archive, file, settings, float.
@MainActor
enum ChatWorkspaceActions {
    static func extend(_ menu: NSMenu, chat: AIChatState, workspace: ChatWorkspaceCoordinator) {
        let id = chat.session.id
        if workspace.history.conversation(id: id) != nil {
            menu.addItem(.separator())
            menu.addItem(
                WorkspaceMenuItem(String(localized: "Branch Chat"), symbol: "arrow.triangle.branch") {
                    workspace.branch(id)
                })
            let archived = workspace.workspace.isArchived(id)
            menu.addItem(
                WorkspaceMenuItem(
                    archived ? String(localized: "Unarchive") : String(localized: "Archive"),
                    symbol: archived ? "tray.and.arrow.up" : "archivebox"
                ) {
                    archived ? workspace.unarchive(id) : workspace.archive(id)
                })
            let move = NSMenuItem(title: String(localized: "Move to Folder"), action: nil, keyEquivalent: "m")
            move.keyEquivalentModifierMask = [.control, .command]
            move.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            move.submenu = ChatMoveNSMenu.build(chat: id, workspace: workspace)
            menu.addItem(move)
        }
        menu.addItem(.separator())
        menu.addItem(
            WorkspaceMenuItem(
                String(localized: "Chat Settings"), symbol: "sidebar.right", key: "i", modifiers: [.command, .shift]
            ) {
                workspace.toggleSettingsSidebar?()
            })
        let float = WorkspaceMenuItem(
            String(localized: "Keep Window on Top"), symbol: "pin.square", key: "t", modifiers: [.command, .option]
        ) {
            workspace.toggleFloatingWindow?()
        }
        float.state = workspace.settings.floatsOnTop ? .on : .off
        menu.addItem(float)
    }
}
