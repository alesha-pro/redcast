import Foundation

/// Root search's `@handle task`: completing a handle, opening a chat, or running in the background.
extension AgentCoordinator {
    /// Root search's rows for `@…`; nil leaves the query to ordinary search.
    func taskClaim(for query: String) -> FallbackClaim? {
        // Ordinary searches pay one character's comparison, and never build a handle.
        guard let first = query.first, first == "@" || first == " ", core.settings.aiEnabled,
            !agents.isEmpty
        else { return nil }
        let handles = AgentTaskAddress.handles(for: agents)
        guard let address = AgentTaskAddress.parse(query, handles: handles) else { return nil }
        let handle = { (id: UUID) in "@" + (handles.first { $0.id == id }?.handle ?? "") }
        let configure: () -> Void = { [weak self] in self?.showAgentSettings() }
        switch address {
        case .completing(let ids):
            let rows = ids.compactMap { id in
                store.agent(id: id).map { (Fallback.agentPick(id), Self.row(.agentPick(id), $0, handle(id))) }
            }
            return FallbackClaim(title: String(localized: "Agents"), rows: rows, configure: configure)
        case .task(let id, let text):
            guard let agent = store.agent(id: id) else { return nil }
            guard !text.isEmpty else {
                let hint = String(localized: "Type a task, or press Return to chat")
                return FallbackClaim(
                    title: String(localized: "Agents"),
                    rows: [(.agentPick(id), Self.row(.agentPick(id), agent, hint))], configure: configure)
            }
            return FallbackClaim(
                title: Fallback.sectionTitle(query: text),
                rows: [(.agent(id), Self.row(.agent(id), agent, handle(id)))], configure: configure)
        }
    }

    /// ↵: complete the handle, open a chat, or ask the agent in front of you.
    func runTask(_ fallback: Fallback, query: String) {
        switch fallback {
        case .agentPick(let id):
            guard let agent = store.agent(id: id) else { return }
            if case .task(id, "")? = address(query) {
                core.paletteCoordinator.hidePalette(restoreFocus: false)
                startChat(with: agent)
                return
            }
            let handle = AgentTaskAddress.handles(for: agents).first { $0.id == id }?.handle ?? ""
            core.palette.rewriteQuery("@\(handle) ")
        case .agent(let id):
            guard let agent = store.agent(id: id), case .task(id, let text)? = address(query),
                !text.isEmpty
            else { return }
            // Quick AI hosts only agents on a chat's model; a CLI agent answers in AI Chat instead.
            if agent.runtime == nil {
                askInQuickAI(text, with: agent)
            } else {
                core.paletteCoordinator.hidePalette(restoreFocus: false)
                startChat(with: agent)
                core.aiChatCoordinator.send(text, in: core.aiChatCoordinator.chats.window)
            }
        case .builtin, .quicklink:
            return
        }
    }

    /// ⌘↵ on a task row: the same task, run in the background and saved as an AI Chat chat.
    func runTaskInBackground(_ fallback: Fallback, query: String) -> Bool {
        guard case .agent(let id) = fallback, let agent = store.agent(id: id),
            case .task(id, let text)? = address(query), !text.isEmpty
        else { return false }
        if case .success = background.start(text, with: agent) {
            core.paletteCoordinator.hidePalette()
        }
        return true
    }

    /// A fresh Quick AI chat bound to the agent, already asked, in the open palette.
    private func askInQuickAI(_ text: String, with agent: AgentProfile) {
        let chat = core.aiChats.quickAI
        chat.startNewChat()
        setAgent(agent, for: chat)
        core.paletteCoordinator.showPalette(mode: .ai)
        core.quickAICoordinator.send(text)
    }

    /// Run Agent Task: root search seeded with `@`; a hotkey bound with no agent does nothing.
    func showTaskPrompt() {
        guard core.settings.aiEnabled, !agents.isEmpty else { return }
        core.paletteCoordinator.showPalette(mode: .launcher, seeding: "@")
    }

    func showAgentSettings() {
        core.paletteCoordinator.hidePalette(restoreFocus: false)
        core.settingsCoordinator.showSettings(tab: .ai, revealing: .section(.aiAgents))
    }

    private func address(_ query: String) -> AgentTaskAddress? {
        AgentTaskAddress.parse(query, handles: AgentTaskAddress.handles(for: agents))
    }

    /// Fallback rows render an `AppEntry` and are never indexed, so their ids name no launcher row.
    private static func row(_ fallback: Fallback, _ agent: AgentProfile, _ subtitle: String) -> AppEntry {
        AppEntry(
            id: fallback.id, name: agent.name,
            url: URL(string: "tinycast://agent/" + agent.id.uuidString.lowercased())!,
            bundleID: nil, kind: .agent, subtitle: subtitle, symbolName: agent.symbol,
            ownerName: String(localized: "Agent"))
    }
}

/// The ⌘K menu of an agent's row in root search.
@MainActor
enum AgentTaskActionsMenu {
    /// Nil for any fallback that isn't an agent's.
    static func content(
        fallback: Fallback, entry: AppEntry, query: String, core: AppCore
    ) -> PopoverMenuContent? {
        let agents = core.agentCoordinator
        let settings = PopoverMenuItem(
            title: String(localized: "Agent Settings…"), systemImage: "slider.horizontal.3",
            startsSection: true
        ) { agents.showAgentSettings() }
        switch fallback {
        case .agentPick:
            return PopoverMenuContent(
                header: entry.name,
                items: [
                    PopoverMenuItem(
                        title: fallback.openVerb, systemImage: "person.crop.circle", shortcut: "↵"
                    ) { agents.runTask(fallback, query: query) },
                    settings
                ])
        case .agent:
            return PopoverMenuContent(
                header: entry.name,
                items: [
                    PopoverMenuItem(
                        title: fallback.openVerb, systemImage: "bubble.left.and.bubble.right",
                        shortcut: "↵"
                    ) { agents.runTask(fallback, query: query) },
                    PopoverMenuItem(
                        title: String(localized: "Run in Background"),
                        systemImage: "person.crop.circle.badge.clock", shortcut: "⌘↵"
                    ) { _ = agents.runTaskInBackground(fallback, query: query) },
                    settings
                ])
        case .builtin, .quicklink:
            return nil
        }
    }
}
