import AppKit

/// Fork: AI Chat's coordinator is the workspace's host; everything here routes to what it has.
extension AIChatCoordinator: ChatWorkspaceHost {
    func closeWindow() {
        _ = closeWindowIfKey()
    }

    func isBackgroundRun(_ id: UUID) -> Bool {
        agents.runs?.run(id) != nil
    }

    var isWindowInFront: Bool {
        NSApp.isActive && NSApp.keyWindow?.identifier == AIChatWindowChrome.windowIdentifier
    }

    func openChatInWindow(id: UUID) {
        guard chats.openInWindow(id: id) else { return }
        showWindow()
    }

    func newChat(agentID: UUID?) {
        newChat()
        guard let agentID, let agent = agents.agents.first(where: { $0.id == agentID }) else { return }
        agents.chooseAgent(agent, for: chats.window)
    }

    func confirm(title: String, message: String, symbol: String, confirmTitle: String) async -> Bool {
        await AppCore.shared.confirm(
            title: title, message: message, symbol: symbol, confirmTitle: confirmTitle)
    }

    func showMessage(_ message: String) {
        AppCore.shared.showMessage(message)
    }

    func copyChats(ids: [UUID]) {
        let texts = ids.compactMap { id -> String? in
            guard let session = chats.holder(of: id)?.session ?? history.session(id: id) else { return nil }
            return session.markdownTranscript(title: history.conversation(id: id)?.displayTitle ?? session.title)
        }
        guard !texts.isEmpty else { return }
        Paster.copyPlainText(texts.joined(separator: "\n\n---\n\n"))
        showMessage(String(localized: "\(texts.count) chats copied"))
    }

    func forgetChat(id: UUID) {
        AppCore.shared.chatGPTSubscription.turns.discardConversation(id: id)
        agents.chatDeleted(id)
    }

    var agentChoices: [ChatAgentChoice] {
        agents.agents.map { ChatAgentChoice(id: $0.id, name: $0.name, symbol: $0.symbol, hue: $0.hue) }
    }

    func agentID(ofChat id: UUID) -> UUID? {
        agents.store.agent(forChat: id)?.id
    }

    func bindAgent(_ id: UUID?, toChat chat: UUID) {
        agents.store.setAgent(id, forChat: chat)
    }

    var workspace: ChatWorkspaceCoordinator { AppCore.shared.chatWorkspace }
}

/// Fork: the settings sidebar's facts, read from the same places the composer's menus read.
extension AIChatCoordinator: ChatSettingsSource {
    func settingsState(for chat: AIChatState) -> ChatSettingsState {
        let id = chat.session.id
        let conversation = history.conversation(id: id)
        let can = capabilities(for: chat)
        let ownRuntime = agents.runsOwnRuntime(chat)
        var state = ChatSettingsState(
            chatID: id, isSaved: conversation != nil,
            title: conversation?.displayTitle ?? "",
            placeholderTitle: conversation?.title ?? String(localized: "New Chat"),
            agent: agentMenu(for: chat),
            creativity: workspace.workspace.placement(of: id).creativity,
            creativityApplies: !ownRuntime && takesTemperature(model(for: chat)),
            instructions: workspace.workspace.placement(of: id).instructions ?? "",
            webSearch: can.webSearch ? aiSettings.webSearchEnabled : nil,
            tools: toolsFacts(for: chat, takesTools: can.tools),
            usage: usageFacts(for: chat))
        state.pickers = ownRuntime ? agentPickers(for: chat) : [modelMenu(for: chat), reasoningMenu(for: chat)]
        state.rename = { [weak self] in self?.rename(id: id, to: $0) }
        state.setWebSearch = { [weak self] in self?.aiSettings.webSearchEnabled = $0 }
        state.showSettings = { [weak self] in self?.showSettings() }
        return state
    }

    func modelSummary(for chat: AIChatState) -> ChatModelSummary {
        let agent = agents.agent(for: chat).map {
            ChatAgentChoice(id: $0.id, name: $0.name, symbol: $0.symbol, hue: $0.hue)
        }
        if agents.runsOwnRuntime(chat) {
            let model = agents.options(for: chat)?.model?.currentTitle
            return ChatModelSummary(
                icon: Self.settingsIcon(agents.modelIcon(for: chat)), model: model ?? agent?.name ?? "",
                agent: agent)
        }
        let selected = model(for: chat)
        return ChatModelSummary(
            icon: Self.settingsIcon(modelIcon(of: selected)),
            model: modelTitle(of: selected, among: modelOptions), agent: agent)
    }

    /// The chat's Creativity as a temperature, where its route takes one.
    func temperature(for chat: AIChatState) -> Double? {
        guard takesTemperature(model(for: chat)) else { return nil }
        return workspace.temperature(for: chat.session.id)
    }

    /// Only an HTTP route sends a temperature; Gemini 3 loops below its own, a ChatGPT plan refuses one.
    func takesTemperature(_ selection: AIModelSelection?) -> Bool {
        guard case .api(let connection, let model, _)? = selection,
            let route = aiSettings.connection(id: connection), route.provider != .codexPlan
        else { return false }
        return AIBrand.resolve(provider: route.provider, model: model) != .gemini
    }

    private func agentMenu(for chat: AIChatState) -> ChatSettingsMenu? {
        guard !agents.agents.isEmpty else { return nil }
        let current = agents.agent(for: chat)
        let none = ChatSettingsMenu.Choice(
            id: "none", title: String(localized: "No Agent"), icon: .symbol("person.crop.circle", nil),
            isOn: current == nil, select: { [weak self] in self?.agents.chooseAgent(nil, for: chat) })
        let choices = agents.agents.map { agent in
            ChatSettingsMenu.Choice(
                id: agent.id.uuidString, title: agent.name, icon: .tile(agent.symbol, agent.hue),
                isOn: current?.id == agent.id,
                select: { [weak self] in self?.agents.chooseAgent(agent, for: chat) })
        }
        var menu = ChatSettingsMenu(
            id: "agent", label: String(localized: "Agent"), title: current?.name ?? String(localized: "No Agent"),
            icon: current.map { .tile($0.symbol, $0.hue) } ?? .symbol("person.crop.circle", nil),
            groups: [
                .init(id: "none", choices: [none]),
                .init(id: "agents", title: String(localized: "Agents"), choices: choices)
            ],
            help: String(localized: "Choose this chat's agent"))
        menu.footer = (String(localized: "Manage Agents…"), { [weak self] in self?.showSettings() })
        return menu
    }

    private func modelMenu(for chat: AIChatState) -> ChatSettingsMenu {
        let groups = modelGroups
        let selected = model(for: chat)
        var menu = ChatSettingsMenu(
            id: "model", label: String(localized: "Model"),
            title: modelTitle(of: selected, among: groups.flatMap(\.options)),
            icon: Self.settingsIcon(modelIcon(of: selected)),
            groups: groups.map { group in
                ChatSettingsMenu.Group(
                    id: group.source.storageKey, title: group.title,
                    choices: group.options.map { option in
                        ChatSettingsMenu.Choice(
                            id: String(describing: option.selection), title: option.title,
                            icon: Self.settingsIcon(option.menuIcon),
                            isOn: selected.map(option.matches) ?? false,
                            select: { [weak self] in self?.selectModel(option, in: chat) })
                    })
            },
            help: String(localized: "Switch this chat's model"))
        if groups.isEmpty {
            menu.footer = (String(localized: "Configure AI…"), { [weak self] in self?.showSettings() })
        }
        return menu
    }

    private func reasoningMenu(for chat: AIChatState) -> ChatSettingsMenu {
        let efforts = reasoningEfforts(for: chat)
        let selected = model(for: chat)?.effort
        return ChatSettingsMenu(
            id: "reasoning", label: String(localized: "Reasoning"),
            title: efforts.isEmpty ? String(localized: "Not with this model") : selectedReasoningTitle(for: chat),
            icon: .symbol("brain", .magenta),
            groups: [
                .init(
                    id: "efforts",
                    choices: efforts.map { effort in
                        .init(
                            id: effort.id, title: effort.title, isOn: selected == effort.id,
                            select: { [weak self] in self?.selectReasoningEffort(effort, in: chat) })
                    })
            ],
            isEnabled: !efforts.isEmpty,
            help: efforts.isEmpty
                ? String(localized: "This model has no reasoning setting")
                : String(localized: "Change reasoning effort"))
    }

    /// An ACP agent's own selects: its model, reasoning, mode and the rest, as its session lists them.
    private func agentPickers(for chat: AIChatState) -> [ChatSettingsMenu] {
        guard let options = agents.options(for: chat) else { return [] }
        let labelled: [(ACPConfigOption?, String, ChatSettingsIcon?)] = [
            (options.model, String(localized: "Model"), Self.settingsIcon(agents.modelIcon(for: chat))),
            (options.reasoning, String(localized: "Reasoning"), .symbol("brain", .magenta)),
            (options.mode, String(localized: "Mode"), .symbol("slider.horizontal.3", .blue))
        ]
        let main = labelled.compactMap { option, label, icon in
            option.map { acpMenu($0, label: label, icon: icon, in: chat) }
        }
        return main + options.others.map { acpMenu($0, label: $0.name, icon: nil, in: chat) }
    }

    private func acpMenu(
        _ option: ACPConfigOption, label: String, icon: ChatSettingsIcon?, in chat: AIChatState
    ) -> ChatSettingsMenu {
        ChatSettingsMenu(
            id: option.id, label: label, title: option.currentTitle.isEmpty ? label : option.currentTitle,
            icon: icon,
            groups: option.groups.map { group in
                ChatSettingsMenu.Group(
                    id: group.id, title: group.name,
                    choices: group.choices.map { choice in
                        ChatSettingsMenu.Choice(
                            id: choice.value, title: choice.name, detail: choice.description,
                            isOn: option.current == choice.value,
                            select: { [weak self] in self?.agents.setOption(choice.value, of: option, for: chat) })
                    })
            })
    }

    private func toolsFacts(for chat: AIChatState, takesTools: Bool) -> ChatToolsFacts {
        let scope = chat.toolScope
        var facts = ChatToolsFacts(
            takesTools: takesTools, isEnabled: scope.isEnabled,
            servers: mcpServers.map {
                ChatToolsFacts.Server(
                    id: $0.slug, name: $0.name.isEmpty ? $0.slug : $0.name, isOn: scope.allows($0.slug))
            })
        facts.setEnabled = { [weak self] in self?.setToolsEnabled($0, in: chat) }
        facts.toggle = { [weak self] in self?.toggleToolServer($0, in: chat) }
        facts.showSettings = { [weak self] in self?.showMCPSettings() }
        return facts
    }

    private func usageFacts(for chat: AIChatState) -> ChatUsageFacts {
        let report = contextReport(for: chat, detailed: false)
        let replies = chat.session.messages.compactMap(\.usage)
        let costs = replies.compactMap(\.costUSD)
        let tokens = replies.compactMap(\.totalTokens)
        return ChatUsageFacts(
            fill: report.fill, contextTokens: report.usage?.contextTokens,
            contextWindow: report.usage?.contextWindow, inputTokens: report.usage?.inputTokens,
            cachedTokens: report.usage?.cachedInputTokens.flatMap { $0 > 0 ? $0 : nil },
            outputTokens: report.usage?.outputTokens,
            reasoningTokens: report.usage?.reasoningTokens.flatMap { $0 > 0 ? $0 : nil },
            lastCost: report.usage?.costUSD, chatCost: costs.isEmpty ? nil : costs.reduce(0, +),
            chatTokens: tokens.isEmpty ? nil : tokens.reduce(0, +),
            sentMessages: report.sentMessages, totalMessages: report.totalMessages,
            historyBytes: report.historyBytes, budget: report.budget)
    }

    static func settingsIcon(_ icon: PopoverMenuIcon) -> ChatSettingsIcon? {
        switch icon {
        case .symbol(let name): .symbol(name, nil)
        case .asset(let name): .asset(name, icon.brandHue ?? ChatBrandHue.hue(forAsset: name))
        case .file, .thumbnail, .blank: nil
        }
    }
}
