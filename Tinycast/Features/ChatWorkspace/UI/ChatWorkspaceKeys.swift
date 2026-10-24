import AppKit

/// Fork: the workspace's chords in AI Chat's window, asked before upstream's own.
@MainActor
final class ChatWorkspaceKeys {
    private let workspace: ChatWorkspaceCoordinator
    private weak var window: NSWindow?
    private weak var anchor: NSView?

    init(workspace: ChatWorkspaceCoordinator) {
        self.workspace = workspace
    }

    func install(in window: NSWindow, anchor: NSView) {
        self.window = window
        self.anchor = anchor
    }

    private var chat: AIChatState { workspace.chats.window }

    func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = (ASCIIKeyboardLayout.character(for: event) ?? event.charactersIgnoringModifiers)?
            .lowercased()
        switch (modifiers, key) {
        case ([.control, .command], "m"):
            showMoveMenu()
        default:
            return false
        }
        return true
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
