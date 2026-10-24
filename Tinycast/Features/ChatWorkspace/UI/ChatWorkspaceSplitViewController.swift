import AppKit
import SwiftUI

/// Fork: upstream's split view, with the workspace's sidebar in place of the flat list.
final class ChatWorkspaceSplitViewController: NSSplitViewController {
    /// Upstream's name, so the sidebar keeps the width it was given before folders.
    private static let autosaveName = "AIChatSplitView"

    init(coordinator: AIChatCoordinator, workspace: ChatWorkspaceCoordinator, find: ChatFindState) {
        super.init(nibName: nil, bundle: nil)
        let sidebar = ChatWorkspaceSidebar().environment(coordinator).environment(workspace)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: sidebar))
        sidebarItem.minimumThickness = Theme.Size.aiChatSidebarMinimum
        sidebarItem.maximumThickness = Theme.Size.aiChatSidebarMaximum
        sidebarItem.canCollapse = true

        let detail = AIChatDetailView().environment(coordinator).environment(find).environment(workspace)
        let detailItem = NSSplitViewItem(viewController: NSHostingController(rootView: detail))
        detailItem.minimumThickness = Theme.Size.aiChatDetailMinimum

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        splitView.autosaveName = Self.autosaveName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
