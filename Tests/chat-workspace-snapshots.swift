import AppKit
import SwiftUI

/// AI Chat's window drawn offscreen from fixtures, light and dark; run by `chat-snapshots.sh`.
@main
@MainActor
struct ChatWorkspaceSnapshots {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            print("usage: chat-snapshots <output-dir> <scratch-dir>")
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let scratch = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for editing in [false, true] {
                let root = scratch.appendingPathComponent("\(language)-\(name)-\(editing)")
                let fixture = SnapshotFixture(root: root, russian: language == "ru", editing: editing)
                app.appearance = NSAppearance(named: appearance)
                let suffix = editing ? "-editing" : ""
                let url = output.appendingPathComponent("chat-workspace-\(language)-\(name)\(suffix).png")
                render(fixture, appearance: appearance, to: url)
                print(url.path)
            }
        }
    }

    static func render(_ fixture: SnapshotFixture, appearance: NSAppearance.Name, to url: URL) {
        let size = NSSize(width: 1480, height: 1000)
        let window = SnapshotWindow(
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
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
        guard let frame = window.contentView?.superview else { return }
        let bounds = frame.bounds
        guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frame.cacheDisplay(in: bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        withExtendedLifetime(delegate) {}
    }
}

/// Drawn as the key window, so controls show their state as the reader sees them.
final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

final class SnapshotToolbar: NSObject, NSToolbarDelegate {
    private static let sidebar = NSToolbarItem.Identifier("sidebar")
    private static let newChat = NSToolbarItem.Identifier("new")
    private static let search = NSToolbarItem.Identifier("search")
    private static let actions = NSToolbarItem.Identifier("actions")
    private static let settings = NSToolbarItem.Identifier("settings")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace, Self.sidebar, .space, Self.newChat, .sidebarTrackingSeparator, .flexibleSpace,
            Self.search, Self.actions, Self.settings
        ]
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
            Self.actions: "slider.horizontal.3", Self.settings: "sidebar.right"
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

/// The window's three columns, as `ChatWorkspaceSplitViewController` lays them out.
final class SnapshotSplit: NSSplitViewController {
    init(fixture: SnapshotFixture) {
        super.init(nibName: nil, bundle: nil)
        let sidebar = NSSplitViewItem(
            sidebarWithViewController: NSHostingController(
                rootView: ChatWorkspaceSidebar().environment(fixture.workspace)))
        sidebar.minimumThickness = 270
        sidebar.maximumThickness = 270
        addSplitViewItem(sidebar)
        let detail = NSSplitViewItem(
            viewController: NSHostingController(
                rootView: SnapshotDetail(fixture: fixture).environment(fixture.workspace)))
        addSplitViewItem(detail)
        let inspector = NSHostingController(rootView: ChatSettingsSidebar().environment(fixture.workspace))
        // A plain item: an inspector's backdrop does not draw into an offscreen cache.
        let settings = NSSplitViewItem(viewController: inspector)
        settings.minimumThickness = 310
        settings.maximumThickness = 310
        addSplitViewItem(settings)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The transcript as the window draws it, and the slimmer composer under it.
struct SnapshotDetail: View {
    let fixture: SnapshotFixture

    var body: some View {
        let chat = fixture.workspace.chats.window
        VStack(spacing: 0) {
            ChatTranscriptView(
                messages: chat.session.messages, status: nil, usage: chat.usage, surface: .window,
                onRegenerate: {}
            )
            .chatWorkspaceActions(for: chat)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ChatEditingBanner(chat: chat)
                Text(chat.draft.isEmpty ? String(localized: "Ask anything…") : chat.draft)
                    .foregroundStyle(chat.draft.isEmpty ? Theme.Colors.textTertiary : Theme.Colors.textPrimary)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.top, Theme.Spacing.xs)
                HStack(spacing: Theme.Spacing.xxs) {
                    glyph("plus")
                    Spacer(minLength: Theme.Spacing.md)
                    ChatModelChip(chat: chat)
                    glyph("mic")
                    Image(systemName: "arrow.up")
                        .font(Theme.Typography.composerSend)
                        .foregroundStyle(Theme.Colors.composerSendInk)
                        .frame(width: Theme.Size.aiChatComposerControl, height: Theme.Size.aiChatComposerControl)
                        .background(Circle().fill(Theme.Colors.composerSend))
                        .padding(.leading, Theme.Spacing.sm)
                }
            }
            .padding(Theme.Spacing.md)
            .background {
                Color.clear.glassEffect(
                    .regular, in: RoundedRectangle(cornerRadius: Theme.Radius.dialog, style: .continuous))
            }
            .frame(maxWidth: Theme.Size.aiChatReadingWidth)
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.bottom, Theme.Spacing.xxl)
            .padding(.top, Theme.Spacing.sm)
        }
        .tint(Theme.Colors.accent)
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(Theme.Typography.composerSymbol)
            .foregroundStyle(Theme.Colors.textSecondary)
            .frame(width: Theme.Size.aiChatComposerControl, height: Theme.Size.aiChatComposerControl)
    }
}

/// Chats, folders and an open conversation laid out the way the owner's own sidebar is.
@MainActor
final class SnapshotFixture {
    let workspace: ChatWorkspaceCoordinator
    let host = SnapshotHost()
    let source: SnapshotSettingsSource
    let text: SnapshotText

    init(root: URL, russian: Bool, editing: Bool) {
        text = russian ? .ru : .en
        try? FileManager.default.removeItem(at: root)
        let history = ChatHistoryStore(directory: root)
        let defaults = UserDefaults(suiteName: "tinycast-snapshots-\(UUID().uuidString)")!
        workspace = ChatWorkspaceCoordinator(
            store: ChatWorkspaceStore(directory: root),
            settings: ChatWorkspaceSettings(defaults: defaults), history: history,
            chats: AIChatSurfacesState(history: history))
        source = SnapshotSettingsSource(text: text)
        source.workspace = workspace
        workspace.host = host
        workspace.settingsSource = source
        workspace.prepare()
        let now = Date()
        let text = text
        func save(_ title: String, hoursAgo: Double, pinned: Bool = false) -> UUID {
            let at = now.addingTimeInterval(-hoursAgo * 3600)
            var session = ChatSession(createdAt: at)
            session.append(ChatMessage(role: .user, text: title, sentAt: at))
            session.append(ChatMessage(role: .assistant, text: "…", sentAt: at))
            history.save(session)
            if pinned { history.setPinned(true, id: session.id) }
            return session.id
        }
        _ = save(text.chats[0], hoursAgo: 30, pinned: true)
        func folder(_ index: Int, _ hue: RaycastHue, _ symbol: String) -> ChatFolder {
            workspace.createFolder(named: text.chats[index], hue: hue, symbol: symbol, instructions: nil, agentID: nil)!
        }
        let work = folder(1, .blue, "briefcase.fill")
        let home = folder(2, .green, "leaf.fill")
        let ideas = folder(3, .orange, "lightbulb.fill")
        workspace.move(save(text.chats[4], hoursAgo: 2), to: work.id)
        workspace.move(save(text.chats[5], hoursAgo: 26), to: work.id)
        workspace.move(save(text.chats[6], hoursAgo: 50), to: home.id)
        workspace.move(save(text.chats[7], hoursAgo: 80), to: ideas.id)
        workspace.toggleCollapsed(ideas.id)
        _ = save(text.chats[9], hoursAgo: 1)
        _ = save(text.chats[10], hoursAgo: 28)
        _ = save(text.chats[11], hoursAgo: 100)
        _ = save(text.chats[12], hoursAgo: 400)
        workspace.archive(save(text.chats[13], hoursAgo: 900))
        workspace.trash(save(text.chats[14], hoursAgo: 700))

        var open = ChatSession(createdAt: now.addingTimeInterval(-600))
        open.append(ChatMessage(role: .user, text: text.question, sentAt: now.addingTimeInterval(-600)))
        open.append(Self.reply(text, at: now.addingTimeInterval(-560)))
        open.append(ChatMessage(role: .user, text: text.followUp, sentAt: now.addingTimeInterval(-300)))
        open.append(
            ChatMessage(
                role: .assistant, text: text.answer, sentAt: now.addingTimeInterval(-280),
                usage: AIUsage(
                    inputTokens: 7_480, outputTokens: 214, cachedInputTokens: 6_144, contextWindow: 200_000,
                    costUSD: 0.0061)))
        history.save(open)
        history.rename(id: open.id, to: text.chats[8])
        workspace.move(open.id, to: work.id)
        workspace.setInstructions(text.instructions, of: open.id)
        workspace.setCreativity(.medium, of: open.id)
        history.load()
        _ = workspace.chats.openInWindow(id: open.id)
        if editing { workspace.beginEditing(in: workspace.chats.window) }
    }

    private static func reply(_ text: SnapshotText, at date: Date) -> ChatMessage {
        ChatMessage(
            role: .assistant, text: text.reply, sentAt: date,
            searches: [ChatSearch(query: text.query, isComplete: true, textOffset: 0, sequence: 1)],
            toolUses: [
                ChatToolUse(
                    callID: "1", origin: "", title: "read_file: Sources/Store.swift", state: .completed,
                    textOffset: 0, sequence: 2),
                ChatToolUse(
                    callID: "2", origin: "GitHub", title: "search_issues", state: .completed,
                    textOffset: 0, sequence: 3)
            ],
            reasoning: [ChatReasoning(text: "…", textOffset: 0, duration: 4)],
            usage: AIUsage(
                inputTokens: 6_120, outputTokens: 838, cachedInputTokens: 2_048, reasoningTokens: 312,
                contextWindow: 200_000, costUSD: 0.0187))
    }

    var title: String { text.chats[8] }
    var subtitle: String { "Claude Sonnet 4.5 · Redcast" }
}

struct SnapshotText {
    let chats: [String]
    let question: String
    let query: String
    let reply: String
    let followUp: String
    let answer: String
    let instructions: String

    static let en = SnapshotText(
        chats: [
            "Weekly planning template", "Work", "Home", "Ideas", "Quarterly report outline",
            "Review the API migration", "Garden watering schedule", "Podcast episode ideas",
            "Swift concurrency: actors vs. tasks", "Translate the release notes", "Fix the flaky CI job",
            "Trip to Lisbon", "Bread recipe", "Old conference notes", "Draft I gave up on"
        ],
        question: "How do actors differ from tasks in Swift concurrency? A short example, please.",
        query: "swift actor vs task isolation",
        reply: """
            **A task is work; an actor is a place.** A `Task` runs code concurrently, while an `actor` \
            owns state and lets one caller in at a time.

            - Use a **task** to start work that may run alongside other work.
            - Use an **actor** to protect state that several tasks touch.

            ```swift
            actor Counter {
                private var value = 0
                func increment() -> Int {
                    value += 1
                    return value
                }
            }
            ```

            See [The Swift Programming Language](https://docs.swift.org/swift-book/).
            """,
        followUp: "And how does that fit with @MainActor?",
        answer: "`@MainActor` is a global actor: the same isolation, bound to the main thread.",
        instructions: "Answer briefly, with Swift examples.")

    static let ru = SnapshotText(
        chats: [
            "Шаблон планирования недели", "Работа", "Дом", "Идеи", "План квартального отчёта",
            "Ревью миграции API", "График полива сада", "Идеи для подкаста",
            "Swift concurrency: акторы и задачи", "Перевод заметок к релизу", "Чиним нестабильный CI",
            "Поездка в Лиссабон", "Рецепт хлеба", "Заметки с конференции", "Черновик, который бросил"
        ],
        question: "Чем акторы отличаются от задач в Swift concurrency? Дай короткий пример.",
        query: "swift actor vs task isolation",
        reply: """
            **Задача — это работа, актор — это место.** `Task` выполняет код параллельно, а `actor` \
            владеет состоянием и пускает к нему по одному вызывающему.

            - **Задача** — чтобы запустить работу рядом с другой работой.
            - **Актор** — чтобы защитить состояние, которое трогают несколько задач.

            ```swift
            actor Counter {
                private var value = 0
                func increment() -> Int {
                    value += 1
                    return value
                }
            }
            ```

            Подробнее: [The Swift Programming Language](https://docs.swift.org/swift-book/).
            """,
        followUp: "А как это сочетается с @MainActor?",
        answer: "`@MainActor` — глобальный актор: та же изоляция, привязанная к главному потоку.",
        instructions: "Отвечай кратко, с примерами на Swift.")
}

/// What `AIChatCoordinator` would build for the open chat: a Claude model on an API route.
@MainActor
final class SnapshotSettingsSource: ChatSettingsSource {
    let text: SnapshotText
    weak var workspace: ChatWorkspaceCoordinator?
    private let agent = ChatAgentChoice(id: UUID(), name: "Redcast", symbol: "terminal.fill", hue: .red)

    init(text: SnapshotText) {
        self.text = text
    }

    func modelSummary(for chat: AIChatState) -> ChatModelSummary {
        ChatModelSummary(icon: .asset("AIBrandClaude", .orange), model: "Claude Sonnet 4.5", agent: agent)
    }

    func settingsState(for chat: AIChatState) -> ChatSettingsState {
        let placement = workspace?.workspace.placement(of: chat.session.id)
        let usage = chat.session.messages.compactMap(\.usage)
        let last = usage.last
        func menu(_ id: String, _ label: String, _ title: String, _ icon: ChatSettingsIcon) -> ChatSettingsMenu {
            ChatSettingsMenu(id: id, label: label, title: title, icon: icon, groups: [])
        }
        return ChatSettingsState(
            chatID: chat.session.id, isSaved: true, title: text.chats[8], placeholderTitle: "",
            agent: menu("agent", String(localized: "Agent"), agent.name, .tile(agent.symbol, agent.hue)),
            pickers: [
                menu("model", String(localized: "Model"), "Claude Sonnet 4.5", .asset("AIBrandClaude", .orange)),
                menu(
                    "reasoning", String(localized: "Reasoning"),
                    String(localized: "creativity-medium", defaultValue: "Medium"), .symbol("brain", .magenta))
            ],
            creativity: placement?.creativity, creativityApplies: true,
            instructions: placement?.instructions ?? "", webSearch: true,
            tools: ChatToolsFacts(
                takesTools: true, isEnabled: true,
                servers: [.init(id: "github", name: "GitHub", isOn: true), .init(id: "linear", name: "Linear", isOn: false)]),
            usage: ChatUsageFacts(
                fill: Double(last?.contextTokens ?? 0) / 200_000, contextTokens: last?.contextTokens,
                contextWindow: last?.contextWindow, inputTokens: last?.inputTokens,
                cachedTokens: last?.cachedInputTokens, outputTokens: last?.outputTokens,
                reasoningTokens: last?.reasoningTokens, lastCost: last?.costUSD,
                chatCost: usage.compactMap(\.costUSD).reduce(0, +),
                chatTokens: usage.compactMap(\.totalTokens).reduce(0, +),
                sentMessages: chat.session.messages.count, totalMessages: chat.session.messages.count,
                historyBytes: chat.session.historyBytes, budget: ChatSession.defaultTextBudget))
    }
}

@MainActor
final class SnapshotHost: ChatWorkspaceHost {
    func openChat(id: UUID) {}
    func openChatInWindow(id: UUID) {}
    func closeWindow() {}
    func isBackgroundRun(_ id: UUID) -> Bool { false }
    var isWindowInFront: Bool { true }
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

// MARK: - Stand-ins for app plumbing the transcript reaches and a picture does not need

extension EnvironmentValues {
    @Entry var chatFileLinks: ChatFileLinks?
    @Entry var chatFilesDirectory: String?
}

extension View {
    func chatFiles(for message: ChatMessage) -> some View { self }

    func glyphTint(_ hue: RaycastHue?, otherwise neutral: Color = Theme.Colors.textSecondary) -> some View {
        foregroundStyle(hue?.color ?? neutral)
    }
}

enum Paster {
    static func copyPlainText(_ text: String) {}
}

@MainActor
enum ChatFileActions {
    static func clicked(_ link: Any) -> Bool { false }
    static func menu(for event: NSEvent, in view: NSView) -> NSMenu? { nil }
}

extension AgentProfile {
    var hue: RaycastHue { RaycastHue.agent(named: color, id: id) }
}

struct GlyphTile: View {
    let symbol: String
    let hue: RaycastHue
    var size: CGFloat = Theme.Size.settingsRowIcon
    var isSelected = false

    var body: some View { ChatFolderTile(symbol: symbol, hue: hue, size: size) }
}
