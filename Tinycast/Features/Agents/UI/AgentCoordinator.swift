import AppKit
import Observation

/// Agents for AI Chat: which chat has one, what its turns are told, and running its tools.
@MainActor
@Observable
final class AgentCoordinator {
    let store: AgentStore
    unowned let core: AppCore

    /// Read off-main and kept, so a send never waits on the disk; refreshed after every use.
    @ObservationIgnored private var contexts: [UUID: AgentContext] = [:]
    @ObservationIgnored private var refreshing: Set<UUID> = []
    /// "Allow for This Chat", per family and risk; never written down.
    @ObservationIgnored private var chatGrants: [UUID: Set<AgentGrant>] = [:]
    /// Made on first need and dropped once idle, so a Mac with no schedule holds none of it.
    private(set) var backgroundRuns: AgentBackgroundCoordinator?
    /// The one Agents menu-bar item, made only while a run or a live session has something to show.
    @ObservationIgnored var menuBarItem: AgentsStatusItem?
    /// An agent whose editor Settings › AI › Agents should open; the section takes and clears it.
    var pendingEdit: UUID?
    /// Every agent question queues here, a chat's and an unattended run's alike.
    @ObservationIgnored let consentGate = AgentConsentGate()

    @ObservationIgnored private var builtACPHost: AgentACPHost?
    /// Settings' agents for Quick AI's and AI Chat's new chats, each read on first use.
    @ObservationIgnored private(set) lazy var quickAIDefault = AgentDefaultStore(.aiQuickAIAgent)
    @ObservationIgnored private(set) lazy var chatDefault = AgentDefaultStore(.aiChatAgent)
    /// Unsent chats that said No Agent, so Settings' agent stays out of them until they speak.
    var declinedDefault: Set<UUID> = []

    /// Built on first use, so a Mac that runs no ACP agent never holds one.
    var acpHost: AgentACPHost {
        if let builtACPHost { return builtACPHost }
        let host = AgentACPHost(
            store: store,
            permit: { [weak self] agent, request in await self?.permit(request, by: agent) },
            context: { [weak self] agent in self?.context(for: agent).briefing() },
            briefing: { [weak self] chatID in
                self?.backgroundRuns?.isUnattended(chatID) == true ? AgentBackgroundBriefing.acp : nil
            })
        host.onOptions = { [weak self] chatID, agentID, options in
            self?.chatOptions[chatID] = options
            if let options { self?.agentOptions[agentID] = options }
        }
        host.onCommands = { [weak self] chatID, agentID, commands in
            if let chatID { self?.chatCommands[chatID] = commands }
            if let commands { self?.agentCommands[agentID] = commands }
        }
        host.onCost = { [weak self] chatID, cost in self?.backgroundRuns?.reportCost(cost, forChat: chatID) }
        builtACPHost = host
        return host
    }

    /// A chat's ACP session and briefing go; with no host built, only the stored id is left.
    func forgetACPSession(ofChat id: UUID) {
        chatOptions[id] = nil
        if let builtACPHost {
            builtACPHost.forget(chatID: id)
        } else {
            store.setACPSession(nil, forChat: id)
        }
    }

    /// Observed: the composer's selects follow the session, including the agent's own moves.
    private(set) var chatOptions: [UUID: ACPSessionOptions] = [:]
    /// What the agent offered last, so a new chat and the editor can pick before a session starts.
    private(set) var agentOptions: [UUID: ACPSessionOptions] = [:]
    /// Observed like the selects: a live session's slash commands, then the agent's last list.
    private(set) var chatCommands: [UUID: [ACPCommand]] = [:]
    /// A chat's run that takes messages between its steps, while it lasts.
    @ObservationIgnored private var steerings: [UUID: AgentSteering] = [:]
    private(set) var agentCommands: [UUID: [ACPCommand]] = [:]

    init(store: AgentStore, core: AppCore) {
        self.store = store
        self.core = core
    }

    var agents: [AgentProfile] { store.agents }

    /// The chat's own agent, or its surface's from Settings until the first message binds it.
    func agent(for chat: AIChatState) -> AgentProfile? {
        ChatToolPolicy.agent(
            bound: store.agent(forChat: chat.session.id), quickAI: quickAIAgent, window: chatAgent,
            surface: surface(of: chat), isUnsent: chat.session.messages.isEmpty,
            declined: declinedDefault.contains(chat.session.id))
    }

    func setAgent(_ agent: AgentProfile?, for chat: AIChatState) {
        guard store.agent(forChat: chat.session.id)?.id != agent?.id else { return }
        store.setAgent(agent?.id, forChat: chat.session.id)
        if agent == nil { store.removeSummary(forChat: chat.session.id) }
        chatGrants[chat.session.id] = nil
        forgetACPSession(ofChat: chat.session.id)
        if let agent { refresh(agent) }
    }

    /// A chat whose agent brings its own CLI: the model picker has nothing to say about it.
    func runsOwnRuntime(_ chat: AIChatState) -> Bool {
        agent(for: chat)?.runtime != nil
    }

    func acpProvider(
        for chat: AIChatState, servers: @escaping @Sendable () async -> [AIToolServer]
    ) -> (any AIProvider)? {
        guard let agent = agent(for: chat), agent.runtime != nil else { return nil }
        return ACPAgentProvider(host: acpHost, agent: agent, servers: servers)
    }

    func stopAll() {
        backgroundRuns?.stopAll()
        builtACPHost?.stopAll()
    }

    var background: AgentBackgroundCoordinator {
        if let backgroundRuns { return backgroundRuns }
        let made = AgentBackgroundCoordinator(store: store, core: core)
        made.onIdle = { [weak self, weak made] in
            guard let self, let made, self.backgroundRuns === made else { return }
            self.backgroundRuns = nil
            self.refreshMenuBar()
        }
        backgroundRuns = made
        return made
    }

    /// Read by the settings rows; nil while nothing runs in the background at all.
    var runs: AgentRunLedger? { backgroundRuns?.ledger }

    /// AI, agents or schedules changed: the rows follow, and the background half only once needed.
    func apply() {
        let aiEnabled = core.settings.aiEnabled
        core.appIndex.setCommandsVisible([.runAgentTask], aiEnabled && !store.agents.isEmpty)
        publishLauncherRows()
        pruneHotKeys()
        let needs = AgentBackgroundNeeds.of(
            aiEnabled: aiEnabled, agents: store.agents, schedules: store.schedules)
        guard backgroundRuns != nil || needs.any else { return }
        background.apply()
    }

    /// The live session's selects, else the agent's last list on what the chat or agent keeps.
    func options(for chat: AIChatState) -> ACPSessionOptions? {
        guard let agent = agent(for: chat), agent.runtime != nil else { return nil }
        if let live = chatOptions[chat.session.id] { return live }
        let kept = store.acpChoices(forChat: chat.session.id) ?? agent.acpChoices
        return agentOptions[agent.id]?.applying(kept)
    }

    /// The models this agent's last session offered, for its editor; nil until one has started.
    func offeredModels(of agentID: UUID) -> ACPConfigOption? {
        agentOptions[agentID]?.model
    }

    /// The brand the model's own name gives, else that of the CLI that runs it.
    func modelIcon(for chat: AIChatState) -> PopoverMenuIcon {
        let model = options(for: chat)?.model
        let named = model.flatMap { AIBrand.resolve(model: $0.current + " " + $0.currentTitle) }
        let vendor: AIBrand? =
            switch agent(for: chat)?.runtime?.kind {
            case .claudeCode?: .claude
            case .codex?: .openAI
            case .gemini?: .gemini
            case .openCode?: .openCode
            default: nil
            }
        return AIModelOption.icon(named ?? vendor)
    }

    /// Empty for a chat without an ACP agent, so the composer offers nothing there.
    func commands(for chat: AIChatState) -> [ACPCommand] {
        guard let agent = agent(for: chat), agent.runtime != nil else { return [] }
        return chatCommands[chat.session.id] ?? agentCommands[agent.id] ?? []
    }

    /// The agent's default for every new session, and this chat's own, now or when it reloads.
    func setOption(_ value: String, of option: ACPConfigOption, for chat: AIChatState) {
        guard var agent = agent(for: chat), let shown = options(for: chat) else { return }
        let slot = shown.slot(of: option)
        agent.acpChoices[slot] = value
        try? store.update(agent)
        let chatID = chat.session.id
        guard var live = chatOptions[chatID], let host = builtACPHost else {
            var own = store.acpChoices(forChat: chatID) ?? ACPChoices(shown)
            own[slot] = value
            store.setACPChoices(own, forChat: chatID)
            return
        }
        live.select(value, in: option.id)
        chatOptions[chatID] = live
        Task { [weak self] in
            do {
                try await host.setOption(value, for: slot, chatID: chatID)
            } catch {
                self?.core.showMessage(error.localizedDescription, tone: .danger)
            }
        }
    }

    /// A fresh AI Chat that already belongs to the agent, ready for the first message.
    func startChat(with agent: AgentProfile) {
        let chats = core.aiChatCoordinator.chats
        core.aiChatCoordinator.newChat()
        setAgent(agent, for: chats.window)
        core.aiChatCoordinator.showWindow()
    }

    // MARK: - A turn

    /// The agent's part of the instructions; nil for a chat without one.
    func prompt(for chat: AIChatState, hasTools: Bool) -> String? {
        guard let agent = agent(for: chat) else { return nil }
        let prompt = context(for: agent).prompt(
            now: Date(), timeZone: .current, hasTools: hasTools, access: access(forChat: chat.session.id))
        guard backgroundRuns?.isUnattended(chat.session.id) == true else { return prompt }
        return prompt + "\n\n" + AgentBackgroundBriefing.text
    }

    /// An agent chat on Tinycast's loop: its own prompt and the user's standing text, no launcher blurb.
    func loopInstructions(for chat: AIChatState) -> String? {
        guard let agent = agent(for: chat), agent.runtime == nil else { return nil }
        let settings = core.aiSettings
        let unattended = backgroundRuns?.isUnattended(chat.session.id) == true
        let own = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let standing =
            settings.systemPromptEnabled
            ? [settings.choicesEnabled && !unattended ? AIPreamble.choices : "", own] : []
        return context(for: agent).prompt(
            now: Date(), timeZone: .current, hasTools: true,
            standing: standing + (unattended ? [AgentBackgroundBriefing.text] : []),
            access: access(forChat: chat.session.id))
    }

    /// An agent chat's turn on the fork's loop, MCP's tools beside its own; nil leaves it upstream.
    func loop(over base: any AIProvider, mcpTools: [AITool], in chat: AIChatState) -> (any AIProvider)? {
        guard let agent = agent(for: chat), agent.runtime == nil else { return nil }
        let chatID = chat.session.id
        let mcp = core.mcpCoordinator
        let mode = backgroundRuns?.runMode(forChat: chatID) ?? .chat(chatID)
        let compaction = AgentCompaction.Source(
            url: store.summaryURL(forChat: chatID), origin: agent.name,
            history: { @MainActor [weak chat] in
                chat?.session.historyMessages.map {
                    AgentCompaction.Entry(id: $0.id, isUser: $0.role == .user, text: $0.text)
                } ?? []
            })
        // A reply the last turn could not finish is left out of history; this turn gets it back.
        let interrupted = chat.session.messages.last.flatMap { last in
            last.role == .assistant && last.state == .failed && !last.text.isEmpty ? last.text : nil
        }
        // Someone at the chat can steer it; a background run has nobody to send anything.
        var steering: AgentSteering?
        if case .chat = mode {
            let fresh = AgentSteering()
            // The run this turn replaces has ended; the queue already took back what it left.
            _ = steerings.updateValue(fresh, forKey: chatID)?.close()
            steering = fresh
        }
        let turn = loop(
            for: agent, over: base, mode: mode, mcpTools: mcpTools, compaction: compaction,
            lead: AgentTurnLead(resuming: interrupted), steering: steering
        ) { call in
            await mcp.invoke(call, in: chatID)
        }
        guard let turn, backgroundRuns?.isCapped(chatID) == true else { return turn }
        return AgentSpendMeter(base: turn) { [weak self] cost in
            Task { @MainActor in self?.backgroundRuns?.reportCost(cost, forChat: chatID) }
        }
    }

    /// The one place a turn's tools are assembled: a chat now, a run with no window later.
    func loop(
        for agent: AgentProfile, over base: any AIProvider, mode: AgentRunMode,
        mcpTools: [AITool] = [], compaction: AgentCompaction.Source? = nil, lead: AgentTurnLead = AgentTurnLead(),
        steering: AgentSteering? = nil,
        mcp: @escaping @Sendable (AIToolCall) async -> AIToolResult = {
            .failure($0.id, "There is no tool called \($0.name).")
        }
    ) -> AgentLoopProvider? {
        let context = context(for: agent)
        var turn = AgentTurn(
            profile: agent, skills: context.skills, memoryURL: store.memoryURL(for: agent.id),
            mode: mode, isBackground: backgroundRuns?.isUnattended(mode.chatID) == true)
        turn.access = ChatAccess.effective(
            core.chatWorkspace.access(of: mode.chatID), isUserTurn: turn.isUserTurn)
        let run = backgroundRuns?.effort(forChat: mode.chatID)
        let effort = run ?? agent.effortLevel
        let budget = effort.budget
        // One clock for the run and its sub-agents, so a child never outlasts its parent's limit.
        let clock = run.map { _ in AgentRunClock(limit: .seconds(budget.minutes * 60)) }
        var lead = lead
        lead.opening = AgentTurnLead.opening(
            now: Date(), timeZone: .current, budget: budget, effort: effort.rawValue.capitalized + " effort")
        let chatID = mode.chatID
        // An earlier turn's personal reads stay in its replies, so this turn starts narrowed too.
        let personal = store.personalChats.contains(chatID)
        let web = AgentWebScope(unattended: !turn.isUserTurn, personal: personal) { [weak self] in
            Task { @MainActor in self?.store.notePersonal(forChat: chatID) }
        }
        turn.web = web
        let toolset = AgentToolset(
            turn: turn,
            providers: providers(
                for: agent, in: context, over: base, turn: turn, budget: budget, clock: clock, web: web),
            mcpTools: mcpTools, mcp: mcp,
            refused: { [weak self] _ in
                guard case .unattended(let chatID) = mode else { return }
                Task { @MainActor in self?.backgroundRuns?.noteDeclined(chatID) }
            }
        ) { [weak self, access = turn.access] spec, request in
            guard case .chat(let chatID) = mode else { return false }
            return await self?.ask(spec, request, by: agent, in: chatID, access: access) ?? false
        }
        guard !toolset.tools.isEmpty else { return nil }
        return AgentLoopProvider(
            base: AgentWebRounds(base: base, scope: web), toolset: toolset, budget: budget,
            compaction: compaction, outputCap: AgentTurnBudget.outputTokens, origin: agent.name, lead: lead,
            clock: clock, steering: steering)
    }

    /// Send Now on a native agent's run: false when no run of this chat takes messages any more.
    func steer(_ text: String, in chat: AIChatState) -> Bool {
        steerings[chat.session.id]?.push(text) ?? false
    }

    /// A chat's reply ended: its run takes nothing more, and what it never read comes back.
    func endSteering(forChat chatID: UUID) -> [String] {
        steerings.removeValue(forKey: chatID)?.close() ?? []
    }

    /// The registry: one line per family, built per turn so nothing stays resident between turns.
    private func providers(
        for agent: AgentProfile, in context: AgentContext, over base: any AIProvider, turn: AgentTurn,
        budget: AgentRunBudget, clock: AgentRunClock?, web: AgentWebScope
    ) -> [any AgentToolProvider] {
        var providers = familyProviders(for: agent)
        providers.append(AgentPlanTools())
        // An effort with no sub-agents does not offer delegate at all, rather than refuse it.
        if agent.tools.contains(.delegate), budget.subAgents > 0 {
            providers.append(
                delegate(
                    for: agent, in: context, over: base, parent: turn,
                    allowance: AgentSubAgentAllowance(budget.subAgents), clock: clock, web: web))
        }
        return providers
    }

    /// What a sub-agent shares with its parent: every family, but not the plan or a delegate.
    private func familyProviders(for agent: AgentProfile) -> [any AgentToolProvider] {
        var providers: [any AgentToolProvider] = [AgentBuiltInTools()]
        if agent.tools.contains(.web) {
            providers.append(
                WebSearchAgentTools(runner: core.webSearch.runner(reader: AgentToolbox.webFetch)))
        }
        if core.settings.notesEnabled { providers.append(core.notesAI.agentTools) }
        if core.settings.aiEnabled, core.settings.screenAwarenessEnabled {
            providers.append(
                ScreenAgentTools(isEnabled: { @MainActor [weak settings = core.settings] in
                    settings.map { $0.aiEnabled && $0.screenAwarenessEnabled } ?? false
                }))
        }
        return providers
    }

    /// A read-only copy of the agent with no delegate of its own, so sub-agents stop at one level.
    private func delegate(
        for agent: AgentProfile, in context: AgentContext, over base: any AIProvider, parent turn: AgentTurn,
        allowance: AgentSubAgentAllowance, clock: AgentRunClock?, web: AgentWebScope
    ) -> AgentDelegateTools {
        var reader = agent
        reader.access = .readOnly
        reader.tools.remove(.delegate)
        let parent = turn.mode.chatID
        var child = AgentTurn(
            profile: reader, skills: context.skills, memoryURL: store.memoryURL(for: agent.id),
            mode: .unattended(parent), web: web)
        child.access = turn.access
        let toolset = AgentToolset(
            turn: child, providers: familyProviders(for: reader), mcpTools: [],
            // Nobody can answer a sub-agent, so Ask Every Time offers it plain reading only.
            offering: turn.access == .askEveryTime ? [.read] : AgentToolRisk.reads,
            mcp: { .failure($0.id, "There is no tool called \($0.name).") },
            // A sub-agent never asks, so what it is refused counts toward its parent's active run.
            refused: { [weak self] _ in
                Task { @MainActor in
                    guard let runs = self?.backgroundRuns, runs.isUnattended(parent) else { return }
                    runs.noteDeclined(parent)
                }
            },
            ask: { _, _ in false })
        let prompt = AgentContext(
            profile: reader, projectInstructions: context.projectInstructions,
            globalInstructions: context.globalInstructions, skills: context.skills, memory: context.memory
        ).prompt(now: Date(), timeZone: .current, hasTools: true)
        return AgentDelegateTools(
            base: AgentWebRounds(base: base, scope: web, readsMessages: false), toolset: toolset,
            instructions: prompt + "\n\n" + AgentDelegateTools.briefing,
            allowance: allowance,
            opening: AgentTurnLead.opening(
                now: Date(), timeZone: .current, budget: .subAgent, effort: "Sub-task"),
            clock: clock)
    }

    /// Whether this chat's agent is offered `web_search`: Web ticked, and not Never Allow.
    func searchesTheWeb(_ chat: AIChatState) -> Bool {
        guard let agent = agent(for: chat), agent.runtime == nil else { return false }
        return AgentConsentPolicy.rule(for: .network, in: .web, of: agent) != .never
    }

    /// The cached reading when there is one; the first ever is read in place, the rest refresh.
    private func context(for agent: AgentProfile) -> AgentContext {
        defer { refresh(agent) }
        if let cached = contexts[agent.id], cached.profile == agent { return cached }
        let loaded = AgentContextLoader.load(agent, memoryURL: store.memoryURL(for: agent.id))
        contexts[agent.id] = loaded
        return loaded
    }

    /// Read off-main ahead of a first send, unless the cached reading is still this agent's.
    func warmContext(for agent: AgentProfile) {
        guard contexts[agent.id]?.profile != agent else { return }
        refresh(agent)
    }

    func refresh(_ agent: AgentProfile) {
        guard refreshing.insert(agent.id).inserted else { return }
        let memoryURL = store.memoryURL(for: agent.id)
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                AgentContextLoader.load(agent, memoryURL: memoryURL)
            }.value
            guard let self else { return }
            self.refreshing.remove(agent.id)
            if self.store.agent(id: agent.id) == agent { self.contexts[agent.id] = loaded }
        }
    }

    // MARK: - Consent

    /// The chat's Access level while someone is there; a background run's chat keeps its rules.
    func access(forChat id: UUID) -> ChatAccess {
        ChatAccess.effective(
            core.chatWorkspace.access(of: id), isUserTurn: backgroundRuns?.isUnattended(id) != true)
    }

    /// The dialog behind a rule of ask; a chat grant skips it, and Stop voids its answer.
    private func ask(
        _ spec: AgentToolSpec, _ request: AgentConsentRequest, by agent: AgentProfile, in chatID: UUID,
        access: ChatAccess
    ) async -> Bool {
        let grants = access != .askEveryTime
        if grants, chatGrants[chatID]?.contains(spec.grant) == true { return true }
        let title =
            switch (spec.family, spec.risk) {
            case (_, .execute): String(localized: "\(agent.name) wants to run a command")
            case (.files?, .change): String(localized: "\(agent.name) wants to change a file")
            case (.notes?, .change): String(localized: "\(agent.name) wants to add to a note")
            case (.screen?, .personal): String(localized: "\(agent.name) wants to read your screen")
            default: String(localized: "\(agent.name) wants to use \(spec.tool.title)")
            }
        let options =
            [DialogAction(title: String(localized: "Allow"))]
            + (grants ? [DialogAction(title: String(localized: "Allow for This Chat"))] : [])
            + [DialogAction(title: String(localized: "Don't Allow"), role: .cancel)]
        let answer = await choose(
            in: chatID, title: title,
            message: [request.summary, request.detail].filter { !$0.isEmpty }.joined(separator: "\n\n"),
            symbol: agent.symbol, options: options, refusal: options.count - 1)
        // Stop while the dialog was up: the turn is gone, so its answer must not act.
        guard !Task.isCancelled else { return false }
        switch answer {
        case 0: return true
        case 1 where grants:
            chatGrants[chatID, default: []].insert(spec.grant)
            return true
        default: return false
        }
    }

    /// The agent's own options, allows first; the last is the dialog's cancel and refuses once.
    private func permit(_ incoming: ACPPermissionRequest, by agent: AgentProfile) async -> String? {
        let chatID = acpHost.chatID(forSession: incoming.sessionID, of: agent.id)
        let request: ACPPermissionRequest
        switch incoming.answer(under: chatID.map(access(forChat:)) ?? .agentSettings) {
        case .select(let optionID): return optionID
        case .ask(let asked): request = asked
        }
        let options = request.dialogOptions
        guard !options.isEmpty else { return nil }
        let title = request.toolCall.title ?? request.toolCall.kind ?? String(localized: "Use a tool")
        let summary = request.toolCall.summary
        let refusal = request.refusalIndex
        let answer = await choose(
            in: chatID, title: String(localized: "\(agent.name): \(title)"), message: summary,
            symbol: agent.symbol,
            options: options.enumerated().map { index, option in
                DialogAction(
                    title: option.name,
                    role: index == refusal ? .cancel : option.allows ? .standard : .destructive)
            }, refusal: refusal)
        return request.optionID(answering: answer)
    }

    /// One question at a time; an unattended one reaches only someone at the Mac. Nil: refused.
    private func choose(
        in chatID: UUID?, title: String, message: String, symbol: String, options: [DialogAction],
        refusal: Int?
    ) async -> Int? {
        let runs = { [weak self] in self?.backgroundRuns }
        return await consentGate.ask(
            refusal: refusal,
            mode: { chatID.flatMap { runs()?.consentMode(forChat: $0) } ?? .foreground },
            dialogIsUp: { [core] in core.isShowingDialog },
            waiting: { isWaiting in
                if let chatID { runs()?.waiting(chatID, isWaiting) }
            },
            declined: {
                if let chatID { runs()?.noteDeclined(chatID) }
            },
            present: { [core] plan in
                var lines = [message]
                if plan.activates {
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    let run = chatID.flatMap { runs()?.ledger.run($0)?.title } ?? ""
                    lines.append(String(localized: "From a background run: “\(run)”"))
                }
                let text = lines.filter { !$0.isEmpty }.joined(separator: "\n\n")
                return await core.choose(
                    title: title, message: text.isEmpty ? nil : text, symbol: symbol, options: options,
                    defaultIndex: plan.defaultIndex)
            })
    }

    // MARK: - Editing

    func add(_ draft: AgentProfile) throws(AgentProfileError) {
        let agent = try store.add(draft)
        refresh(agent)
        apply()
    }

    func update(_ draft: AgentProfile) throws(AgentProfileError) {
        let previous = store.agent(id: draft.id)
        try store.update(draft)
        contexts[draft.id] = nil
        // A different program or folder is a different agent: its old sessions mean nothing.
        if previous?.runtime != draft.runtime || previous?.directory != draft.directory {
            agentCommands[draft.id] = nil
            agentOptions[draft.id] = nil
            for (chat, agent) in store.chatAgents where agent == draft.id {
                forgetACPSession(ofChat: chat)
            }
        }
        if let agent = store.agent(id: draft.id) { refresh(agent) }
        apply()
    }

    func delete(id: UUID) async {
        guard let agent = store.agent(id: id) else { return }
        guard
            await core.confirm(
                title: String(localized: "Delete “\(agent.name)”?"),
                message: String(
                    localized: "Its chats stay, as plain AI chats. Its notes are deleted with it."),
                symbol: agent.symbol, confirmTitle: String(localized: "Delete"))
        else { return }
        // Before the store forgets which chats were its, so their pending briefings can be found.
        for chat in store.acpSessions.keys where store.agent(forChat: chat)?.id == id {
            forgetACPSession(ofChat: chat)
        }
        do {
            try store.remove(id: id)
        } catch {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        contexts[id] = nil
        agentCommands[id] = nil
        agentOptions[id] = nil
        chatCommands = chatCommands.filter { store.agent(forChat: $0.key) != nil }
        try? FileManager.default.removeItem(at: store.memoryURL(for: id).deletingLastPathComponent())
        removeLauncherReferences(of: id)
        apply()
    }

    /// A deleted chat's agent, notes and pending ACP briefing go with it.
    func chatDeleted(_ id: UUID) {
        store.removeSummary(forChat: id)
        store.forgetPersonal([id])
        forgetACPSession(ofChat: id)
        store.unbind([id])
    }

    // MARK: - Schedules

    @discardableResult
    func saveSchedule(_ draft: AgentSchedule) throws(AgentScheduleError) -> AgentSchedule {
        let saved = try store.saveSchedule(draft, now: Date())
        apply()
        return saved
    }

    func removeSchedule(id: UUID) async {
        guard let schedule = store.schedule(id: id),
            await core.confirm(
                title: String(localized: "Delete “\(schedule.name)”?"),
                message: String(localized: "Its past runs stay in AI Chat."),
                symbol: "clock", confirmTitle: String(localized: "Delete"))
        else { return }
        do {
            try store.removeSchedule(id: id)
        } catch {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        apply()
    }

    /// Run Now: announced like a launcher run; the schedule's next time stays where it was.
    func runNow(_ schedule: AgentSchedule) {
        background.start(schedule, manual: true)
    }

    func setScheduleCap(_ cap: Double?) {
        do {
            try store.setScheduleCap(cap)
        } catch {
            core.showMessage(error.localizedDescription, tone: .danger)
        }
    }
}

extension AppCore {
    /// After chats are deleted, their agents and the notes and ACP sessions those kept go with them.
    func pruneAgentSummaries() {
        guard chatHistory.isAvailable else { return }
        // Recently Deleted's chats are hidden from the history but keep their agents until purged.
        let kept = Set(chatHistory.conversations.map(\.id)).union(chatWorkspace.trashedIDs)
        agentStore.pruneSummaries(keeping: kept)
        for chat in agentStore.acpSessions.keys where !kept.contains(chat) {
            agentCoordinator.forgetACPSession(ofChat: chat)
        }
        // An open chat with no message yet keeps the agent picked for it.
        let open = kept.union(aiChats.live.map(\.session.id))
        agentStore.unbind(agentStore.chatAgents.keys.filter { !open.contains($0) })
        agentStore.forgetPersonal(agentStore.personalChats.subtracting(open))
    }
}
