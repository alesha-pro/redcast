import AppKit
import SwiftUI

/// Fork: upstream's split view with the workspace's sidebar, and the chat's settings on the right.
final class ChatWorkspaceSplitViewController: NSSplitViewController {
    /// Upstream's name, so the sidebar keeps the width it was given before folders.
    private static let autosaveName = "AIChatSplitView"

    init(coordinator: AIChatCoordinator, workspace: ChatWorkspaceCoordinator, find: ChatFindState) {
        super.init(nibName: nil, bundle: nil)
        let sidebar = ChatWorkspaceSidebar().environment(coordinator).environment(workspace)
        let sidebarController = NSHostingController(rootView: sidebar)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = Theme.Size.aiChatSidebarMinimum
        sidebarItem.maximumThickness = Theme.Size.aiChatSidebarMaximum
        sidebarItem.canCollapse = true

        let detail = AIChatDetailView().environment(coordinator).environment(find).environment(workspace)
        let detailItem = NSSplitViewItem(viewController: NSHostingController(rootView: detail))
        detailItem.minimumThickness = Theme.Size.aiChatDetailMinimum

        let settings = NSHostingController(rootView: ChatSettingsSidebar().environment(workspace))
        let settingsItem = NSSplitViewItem(inspectorWithViewController: settings)
        settingsItem.minimumThickness = Theme.Size.chatSettingsMinimum
        settingsItem.maximumThickness = Theme.Size.chatSettingsMaximum
        settingsItem.canCollapse = true
        // A narrow window drops the settings first; the remembered choice stays the reader's.
        settingsItem.canCollapseFromWindowResize = true
        settingsItem.isCollapsed = !workspace.settings.showsInspector
        self.settingsItem = settingsItem
        self.workspace = workspace

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        addSplitViewItem(settingsItem)
        splitView.autosaveName = Self.autosaveName
        workspace.toggleSettingsSidebar = { [weak self] in self?.toggleSettings() }
        let sidebarView = sidebarController.view
        workspace.sidebarHasFocus = { [weak sidebarView] in
            guard let sidebarView, let responder = sidebarView.window?.firstResponder as? NSView else { return false }
            return !(responder is NSText) && responder.isDescendant(of: sidebarView)
        }
    }

    private var settingsItem: NSSplitViewItem?
    private weak var workspace: ChatWorkspaceCoordinator?
    private var closing: NotificationToken?

    /// The transcript goes when the window closes, not when it hides or minimises.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard closing == nil, let window = view.window else { return }
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let workspace = self?.workspace else { return }
                workspace.chats.releaseWindowTranscript { workspace.history.conversation(id: $0) != nil }
            }
        }
        closing = NotificationToken(token, center: .default)
    }

    /// ⇧⌘I, the toolbar button and the sidebar's ✕; the choice is remembered for the next window.
    func toggleSettings() {
        guard let settingsItem else { return }
        let show = settingsItem.isCollapsed
        settingsItem.animator().isCollapsed = !show
        workspace?.settings.showsInspector = show
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
