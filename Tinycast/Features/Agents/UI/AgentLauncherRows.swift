import Foundation

/// Each agent as a launcher row and a chord: ↵ opens a chat, the chord types its `@handle `.
extension AgentCoordinator {
    /// AI on: one row per agent, its handle beside its name so the `@` path is learnt from it.
    func publishLauncherRows() {
        guard core.settings.aiEnabled else { return core.appIndex.setAgents([]) }
        let handles = AgentTaskAddress.handles(for: agents)
        core.appIndex.setAgents(
            agents.map { agent in
                AppEntry(agent, handle: handles.first { $0.id == agent.id }?.handle ?? "")
            })
    }

    /// A chord whose agent went while Tinycast was closed is dropped once `agents.json` has read.
    func pruneHotKeys() {
        guard store.isAvailable else { return }
        for id in core.hotKeys.boundAgentIDs where store.agent(id: id) == nil {
            core.hotKeys.setBinding(nil, for: .agent(id: id))
        }
    }

    /// ↵ on an agent's row: a fresh AI Chat that already belongs to it.
    func startChat(entryID: String) {
        guard core.settings.aiEnabled, let id = AgentProfile.id(fromEntryID: entryID),
            let agent = store.agent(id: id)
        else { return }
        startChat(with: agent)
    }

    /// An agent's chord: root search with `@handle ` typed, ready for a task, or ↵ for a chat.
    func summon(agentID id: UUID) {
        guard core.settings.aiEnabled, let handle = handle(of: id) else { return }
        core.paletteCoordinator.showPalette(mode: .launcher, seeding: "@\(handle) ")
    }

    /// Run in Background… from the row's ⌘K menu: the same `@handle ` path, in the open palette.
    func typeHandle(of id: UUID) {
        guard let handle = handle(of: id) else { return }
        core.palette.rewriteQuery("@\(handle) ")
    }

    /// Settings › AI › Agents with the agent's editor open, through the section's pending request.
    func edit(agentID id: UUID) {
        guard store.agent(id: id) != nil else { return }
        pendingEdit = id
        showAgentSettings()
    }

    func handle(of id: UUID) -> String? {
        AgentTaskAddress.handles(for: agents).first { $0.id == id }?.handle
    }

    /// A deleted agent's row leaves nothing behind: its chord, favorite, alias, hide and ranking.
    func removeLauncherReferences(of id: UUID) {
        let action = HotKeyAction.agent(id: id)
        if core.hotKeys.recordingAction == action { core.hotKeys.recordingAction = nil }
        core.hotKeys.setBinding(nil, for: action)
        let entryID = AgentProfile.entryIDPrefix + id.uuidString.lowercased()
        core.favorites.remove(keys: [entryID])
        core.visibility.removeItemKeys([entryID])
        core.aliases.removeKeys([entryID])
        core.launcherRanking.reset(itemKey: entryID)
    }
}

extension AppEntry {
    /// AI's switch is its only gate (`settingsOwner`), and Suggestions never push it.
    init(_ agent: AgentProfile, handle: String) {
        self.init(
            id: agent.entryID, name: agent.name,
            url: URL(string: "tinycast://agent/" + agent.id.uuidString.lowercased())!,
            bundleID: nil, kind: .agent, settingsOwner: .ai, subtitle: "@" + handle,
            symbolName: agent.symbol)
    }
}

/// The leading rows of an agent's ⌘K menu; Favorites, Change Alias and Change Shortcut follow.
@MainActor
enum AgentLauncherMenu {
    static func leadingItems(app: AppEntry, searchQuery: String, core: AppCore) -> [PopoverMenuItem] {
        guard let id = AgentProfile.id(fromEntryID: app.id) else { return [] }
        let agents = core.agentCoordinator
        return [
            PopoverMenuItem(
                title: String(localized: app.kind.descriptor.openVerb),
                systemImage: "bubble.left.and.bubble.right", shortcut: "↵"
            ) { core.launcherCoordinator.launch(app, searchQuery: searchQuery) },
            PopoverMenuItem(
                title: String(localized: "Run in Background…"), systemImage: "person.crop.circle.badge.clock"
            ) { agents.typeHandle(of: id) },
            PopoverMenuItem(title: String(localized: "Edit Agent"), systemImage: "pencil") {
                agents.edit(agentID: id)
            }
        ]
    }
}
