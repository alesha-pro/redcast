import AppKit
import SwiftUI

/// Renders AI Chat's window offscreen from fixtures, light and dark: `Scripts/fork/chat-snapshots.sh`.
@main
@MainActor
struct ChatWorkspaceSnapshots {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            print("usage: chat-workspace-snapshots <output-dir> <scratch-dir>")
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let scratch = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let language = Locale.preferredLanguages.first?.prefix(2).description ?? "en"
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let fixture = SnapshotFixture(root: scratch.appendingPathComponent("\(language)-\(name)"), russian: language == "ru")
            app.appearance = NSAppearance(named: appearance)
            let url = output.appendingPathComponent("chat-workspace-\(language)-\(name).png")
            render(fixture, appearance: appearance, to: url)
            print(url.path)
        }
    }

    static func render(_ fixture: SnapshotFixture, appearance: NSAppearance.Name, to url: URL) {
        let size = NSSize(width: 1280, height: 820)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.title = fixture.title
        window.subtitle = fixture.subtitle
        let toolbar = NSToolbar(identifier: "Snapshot")
        let delegate = SnapshotToolbar()
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.contentViewController = SnapshotSplit(fixture: fixture)
        window.setContentSize(size)
        window.layoutIfNeeded()
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
        guard let frame = window.contentView?.superview else { return }
        let bounds = frame.bounds
        guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frame.cacheDisplay(in: bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        _ = delegate
    }
}

final class SnapshotToolbar: NSObject, NSToolbarDelegate {
    private static let sidebar = NSToolbarItem.Identifier("sidebar")
    private static let newChat = NSToolbarItem.Identifier("new")
    private static let search = NSToolbarItem.Identifier("search")
    private static let actions = NSToolbarItem.Identifier("actions")
    private static let inspector = NSToolbarItem.Identifier("inspector")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.sidebar, .space, Self.newChat, .sidebarTrackingSeparator, .flexibleSpace,
         Self.search, Self.actions, Self.inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if identifier == Self.search {
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.placeholderString = String(localized: "Find in Chat")
            return item
        }
        let symbols = [
            Self.sidebar: "sidebar.left", Self.newChat: "square.and.pencil",
            Self.actions: "slider.horizontal.3", Self.inspector: "sidebar.right"
        ]
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = symbols[identifier].flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        item.label = identifier.rawValue
        item.target = self
        item.action = #selector(noop)
        return item
    }

    @objc func noop() {}
}

final class SnapshotSplit: NSSplitViewController {
    init(fixture: SnapshotFixture) {
        super.init(nibName: nil, bundle: nil)
        let sidebar = NSSplitViewItem(
            sidebarWithViewController: NSHostingController(
                rootView: ChatWorkspaceSidebar().environment(fixture.workspace)))
        sidebar.minimumThickness = Theme.Size.aiChatSidebarMinimum
        sidebar.maximumThickness = Theme.Size.aiChatSidebarMaximum
        addSplitViewItem(sidebar)
        let detail = NSSplitViewItem(
            viewController: NSHostingController(rootView: SnapshotDetail(fixture: fixture)))
        addSplitViewItem(detail)
        splitView.setPosition(270, ofDividerAt: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

struct SnapshotDetail: View {
    let fixture: SnapshotFixture

    var body: some View {
        Color.clear
    }
}

/// Chats, folders and a window chat laid out the way the owner's own sidebar is.
@MainActor
final class SnapshotFixture {
    let workspace: ChatWorkspaceCoordinator
    let host = SnapshotHost()
    let russian: Bool

    init(root: URL, russian: Bool) {
        self.russian = russian
        try? FileManager.default.removeItem(at: root)
        let history = ChatHistoryStore(directory: root)
        let defaults = UserDefaults(suiteName: "tinycast-snapshots-\(UUID().uuidString)")!
        workspace = ChatWorkspaceCoordinator(
            store: ChatWorkspaceStore(directory: root),
            settings: ChatWorkspaceSettings(defaults: defaults), history: history,
            chats: AIChatSurfacesState(history: history))
        workspace.host = host
        workspace.prepare()
        let now = Date()
        func save(_ title: String, hoursAgo: Double, pinned: Bool = false) -> UUID {
            let at = now.addingTimeInterval(-hoursAgo * 3600)
            var session = ChatSession(createdAt: at)
            session.append(ChatMessage(role: .user, text: title, sentAt: at))
            session.append(ChatMessage(role: .assistant, text: "…", sentAt: at))
            history.save(session)
            if pinned { history.setPinned(true, id: session.id) }
            return session.id
        }
        let t = russian ? Self.ru : Self.en
        let pinned = save(t[0], hoursAgo: 30, pinned: true)
        _ = pinned
        let work = workspace.createFolder(named: t[1], hue: .blue, symbol: "briefcase.fill", instructions: nil, agentID: nil)!
        let home = workspace.createFolder(named: t[2], hue: .green, symbol: "leaf.fill", instructions: nil, agentID: nil)!
        let ideas = workspace.createFolder(named: t[3], hue: .orange, symbol: "lightbulb.fill", instructions: nil, agentID: nil)!
        workspace.move(save(t[4], hoursAgo: 2), to: work.id)
        workspace.move(save(t[5], hoursAgo: 26), to: work.id)
        workspace.move(save(t[6], hoursAgo: 50), to: home.id)
        workspace.move(save(t[7], hoursAgo: 80), to: ideas.id)
        workspace.toggleCollapsed(ideas.id)
        let open = save(t[8], hoursAgo: 0.2)
        _ = save(t[9], hoursAgo: 1)
        _ = save(t[10], hoursAgo: 28)
        _ = save(t[11], hoursAgo: 100)
        _ = save(t[12], hoursAgo: 400)
        history.load()
        _ = workspace.chats.openInWindow(id: open)
    }

    var title: String { russian ? Self.ru[8] : Self.en[8] }
    var subtitle: String { "Gemini 3.8 Flash · Redcast" }

    static let en = [
        "Weekly planning template", "Work", "Home", "Ideas", "Quarterly report outline",
        "Review the API migration", "Garden watering schedule", "Podcast episode ideas",
        "Swift concurrency: actors vs. tasks", "Translate the release notes", "Fix the flaky CI job",
        "Trip to Lisbon", "Bread recipe"
    ]

    static let ru = [
        "Шаблон планирования недели", "Работа", "Дом", "Идеи", "План квартального отчёта",
        "Ревью миграции API", "График полива сада", "Идеи для подкаста",
        "Swift concurrency: акторы и задачи", "Перевод заметок к релизу", "Чиним нестабильный CI",
        "Поездка в Лиссабон", "Рецепт хлеба"
    ]
}

@MainActor
final class SnapshotHost: ChatWorkspaceHost {
    func openChat(id: UUID) {}
    func closeWindow() {}
    func newChat(agentID: UUID?) {}
    func copyChat(id: UUID) {}
    func exportChat(id: UUID) {}
    func deleteChat(id: UUID) async {}
    func confirm(title: String, message: String, symbol: String, confirmTitle: String) async -> Bool { false }
    func showMessage(_ message: String) {}
    func forgetChat(id: UUID) {}
    var agentChoices: [ChatAgentChoice] {
        [ChatAgentChoice(id: UUID(), name: "Redcast", symbol: "terminal.fill", hue: .red)]
    }
    func agentID(ofChat id: UUID) -> UUID? { nil }
    func bindAgent(_ id: UUID?, toChat chat: UUID) {}
}
