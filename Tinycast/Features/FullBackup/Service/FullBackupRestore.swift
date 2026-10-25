import AppKit
import Foundation

/// Section payloads → live stores, through each store's own API so every view sees it at once.
@MainActor
enum FullBackupRestore {
    private static var local: (String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return { FullBackupPaths.local($0, home: home) }
    }

    struct Request: Sendable {
        var layout: FullBackupLayout
        var sections: Set<FullBackupSection>
        var modes: [FullBackupSection: FullBackupImportMode]
        var secrets: FullBackupSecrets?
        var skipped: [String]

        func mode(_ section: FullBackupSection) -> FullBackupImportMode {
            section.descriptor.replaces ? modes[section] ?? .merge : .merge
        }
    }

    /// Ordered so everything a later section points at already exists: agents before shortcuts.
    static func apply(_ request: Request, to core: AppCore) async -> FullBackupReport {
        var report = FullBackupReport()
        report.skippedSections = request.skipped
        let layout = request.layout
        var consents: [FullBackupConsents?] = []
        func payload<P: Decodable>(_ type: P.Type, _ section: FullBackupSection) -> P? {
            guard request.sections.contains(section) else { return nil }
            guard let value = layout.read(type, for: section) else {
                report.problems.append(
                    String(localized: "Couldn't read \(section.descriptor.label) from this file."))
                return nil
            }
            return value
        }
        if let agents = payload(AgentsBackup.self, .agents) {
            let restored = restoreAgents(agents, mode: request.mode(.agents), core, &report)
            report.applied[.agents] = restored
        }
        if let mcp = payload(MCPBackup.self, .mcpServers) {
            consents.append(mcp.consents)
            let restored = restoreMCP(mcp, mode: request.mode(.mcpServers), core, &report)
            report.applied[.mcpServers] = restored
        }
        var folderLinks: [UUID: ChatPlacement] = [:]
        if let ai = payload(AIBackup.self, .ai) {
            consents.append(ai.consents)
            let restored = restoreAI(ai, mode: request.mode(.ai), core, &report)
            report.applied[.ai] = restored
            folderLinks = restoreChatFolders(layout, mode: request.mode(.ai), core)
        }
        if let voice = payload(VoiceBackup.self, .voice) {
            consents.append(voice.consents)
            let restored = restoreVoice(voice, core, &report)
            report.applied[.voice] = restored
        }
        if let actions = payload(QuickActionsBackup.self, .quickActions) {
            consents.append(actions.consents)
            let restored = restoreQuickActions(
                actions, mode: request.mode(.quickActions), core, &report)
            report.applied[.quickActions] = restored
        }
        if let extensions = payload(ExtensionsBackup.self, .extensions) {
            consents.append(extensions.consents)
            let restored = restoreExtensions(extensions, core, &report)
            report.applied[.extensions] = restored
        }
        if let more = payload(MoreBackup.self, .more) {
            consents.append(more.consents)
            let restored = restoreMore(more, core, &report)
            report.applied[.more] = restored
        }
        var placements: [UUID: ChatPlacement] = [:]
        if let chats = payload(ChatHistoryBackup.self, .chatHistory) {
            let restored = await restoreChats(chats, layout: layout, core, &report)
            report.applied[.chatHistory] = restored
            placements = readWorkspace(layout.chatPlacementsURL)?.placements ?? [:]
        }
        if !folderLinks.isEmpty || !placements.isEmpty {
            placeChats(placements, folderLinks: folderLinks, core)
        }
        if let secrets = request.secrets {
            report.secretsRestored = restoreSecrets(secrets, core)
        }
        report.consents = FullBackupImportPolicy.consentsToReview(consents) { isOn($0, core) }
        return report
    }

    // MARK: - Sections

    private static func restoreAgents(
        _ backup: AgentsBackup, mode: FullBackupImportMode, _ core: AppCore, _ report: inout FullBackupReport
    ) -> Int {
        let store = core.agentStore
        let incoming = (backup.agents?.items ?? []).map { FullBackupPaths.agent($0, local) }
        report.droppedRecords += (backup.agents?.dropped ?? 0) + (backup.schedules?.dropped ?? 0)
        let plan = FullBackupMerge.plan(incoming: incoming, existing: store.agents, mode: mode)
        var restored = 0
        do {
            for id in plan.removals { try store.remove(id: id) }
            for agent in plan.upserts {
                if store.agent(id: agent.id) != nil { try store.update(agent) } else { try store.add(agent) }
                restored += 1
                if !FileManager.default.fileExists(atPath: agent.directory) {
                    report.missingFolders.append(agent.name)
                }
            }
        } catch {
            report.problems.append(error.localizedDescription)
        }
        for (rawID, notes) in backup.memories ?? [:] {
            guard let id = UUID(uuidString: rawID), store.agent(id: id) != nil else { continue }
            let url = store.memoryURL(for: id)
            guard mode == .replace || !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(notes.utf8).write(to: url, options: .atomic)
        }
        let paused = FullBackupImportPolicy.pausing(
            (backup.schedules?.items ?? []).filter { store.agent(id: $0.agentID) != nil },
            runningHere: Set(store.schedules.filter(\.isEnabled).map(\.id)))
        report.pausedSchedules += paused.paused
        do {
            if mode == .replace {
                let kept = Set(paused.schedules.map(\.id))
                for schedule in store.schedules where !kept.contains(schedule.id) {
                    try store.removeSchedule(id: schedule.id)
                }
            }
            for schedule in paused.schedules { try store.saveSchedule(schedule, now: Date()) }
            if let cap = backup.scheduleCapUSD { try store.setScheduleCap(cap) }
        } catch {
            report.problems.append(error.localizedDescription)
        }
        let agents = core.agentCoordinator
        if let id = backup.quickAIAgent, store.agent(id: id) != nil { agents.quickAIDefault.agentID = id }
        if let id = backup.chatAgent, store.agent(id: id) != nil { agents.chatDefault.agentID = id }
        return restored
    }

    private static func restoreMCP(
        _ backup: MCPBackup, mode: FullBackupImportMode, _ core: AppCore, _ report: inout FullBackupReport
    ) -> Int {
        let store = core.mcpSettings
        report.droppedRecords += backup.servers?.dropped ?? 0
        let incoming = (backup.servers?.items ?? []).map { FullBackupPaths.server($0, local) }
        let disabled = FullBackupImportPolicy.disabling(
            incoming, enabledHere: Set(store.enabledServers.map(\.id)))
        report.disabledServers += disabled.disabled
        let plan = FullBackupMerge.plan(incoming: disabled.servers, existing: store.servers, mode: mode)
        for id in plan.removals {
            store.remove(id: id)
            try? MCPSecretStore().remove(for: id)
        }
        for server in plan.upserts { store.save(server) }
        return plan.upserts.count
    }

    private static func restoreAI(
        _ backup: AIBackup, mode: FullBackupImportMode, _ core: AppCore, _ report: inout FullBackupReport
    ) -> Int {
        let ai = core.aiSettings
        report.droppedRecords += backup.connections?.dropped ?? 0
        let plan = FullBackupMerge.plan(
            incoming: backup.connections?.items ?? [], existing: ai.connections, mode: mode)
        for id in plan.removals {
            ai.removeConnection(id: id)
            try? KeychainSecretStore.aiAPIKeys.removeSecret(for: id)
            try? KeychainSecretStore.aiRequestHeaders.removeSecret(for: id)
            try? KeychainSecretStore.openRouterManagementKeys.removeSecret(for: id)
        }
        for connection in plan.upserts { ai.save(connection) }
        if let model = backup.defaultModel { ai.select(model) }
        if let flag = backup.webSearch { ai.webSearchEnabled = flag }
        if let flag = backup.choices { ai.choicesEnabled = flag }
        if let text = backup.systemPrompt { ai.systemPrompt = text }
        if let flag = backup.systemPromptEnabled { ai.systemPromptEnabled = flag }
        if let raw = backup.retentionDays, let value = AIRetention(rawValue: raw) { ai.retention = value }
        if let raw = backup.opensTo, let value = AIOpensTo(rawValue: raw) { ai.opensTo = value }
        if let raw = backup.newChatAfterMinutes, let value = AINewChatAfter(rawValue: raw) {
            ai.newChatAfter = value
        }
        if let raw = backup.toolRounds, let value = AIToolRounds(rawValue: raw) { ai.toolRounds = value }
        if backup.shownModels != nil || backup.disabledRoutes != nil {
            ai.restoreModelLists(
                shown: backup.shownModels ?? ai.shownModels,
                disabled: backup.disabledRoutes.map(Set.init) ?? ai.disabledRoutes)
        }
        for (raw, override) in backup.installedOverrides ?? [:] {
            guard let kind = InstalledAIKind(rawValue: raw) else { continue }
            ai.setCommandPath(local(override.commandPath), for: kind)
        }
        if let engines = backup.webSearchEngines { core.webSearch.save(engines) }
        let chat = core.chatWorkspace.settings
        if let days = backup.chatAutoArchiveDays, let value = ChatAutoArchive(rawValue: days) {
            chat.autoArchive = value
        }
        if let flag = backup.chatFloatsOnTop { chat.floatsOnTop = flag }
        report.signInAgain += FullBackupImportPolicy.signsInAgain(backup)
        return plan.upserts.count
    }

    // MARK: - AI Chat's workspace

    private static func readWorkspace(_ url: URL) -> ChatWorkspace? {
        (try? Data(contentsOf: url)).map(ChatWorkspace.init(data:))
    }

    /// Folders by id, as Merge or Replace says; returns which chat the file filed where.
    private static func restoreChatFolders(
        _ layout: FullBackupLayout, mode: FullBackupImportMode, _ core: AppCore
    ) -> [UUID: ChatPlacement] {
        guard let incoming = readWorkspace(layout.chatFoldersURL) else { return [:] }
        let kept = Set(incoming.folders.map(\.id))
        core.chatWorkspace.store.change { workspace in
            if mode == .replace {
                for stale in workspace.folders.map(\.id) where !kept.contains(stale) {
                    workspace.deleteFolder(stale)
                }
            }
            for folder in incoming.folders {
                if workspace.folder(id: folder.id) == nil {
                    workspace.createFolder(named: folder.name, id: folder.id)
                }
                workspace.updateFolder(folder.id) { $0 = folder }
            }
        }
        return incoming.placements
    }

    /// Only chats this Mac has, and only those it has said nothing of yet: a local choice stays.
    private static func placeChats(
        _ placements: [UUID: ChatPlacement], folderLinks: [UUID: ChatPlacement], _ core: AppCore
    ) {
        let existing = Set(core.chatHistory.conversations.map(\.id))
        core.chatWorkspace.store.change { workspace in
            for (chat, placement) in placements
            where existing.contains(chat) && workspace.placement(of: chat).isEmpty {
                if let folder = placement.folderID, workspace.folder(id: folder) != nil {
                    workspace.move(chat, to: folder)
                }
                workspace.setInstructions(placement.instructions, of: chat)
                workspace.setCreativity(placement.creativity, of: chat)
                workspace.setParent(placement.parentID, of: chat)
                if let date = placement.archivedAt { workspace.archive(chat, at: date) }
                if let date = placement.deletedAt {
                    workspace.trash(chat, title: placement.deletedTitle ?? "", at: date)
                }
            }
            for (chat, link) in folderLinks {
                guard existing.contains(chat), let folder = link.folderID, workspace.folder(id: folder) != nil,
                    workspace.folderID(of: chat) == nil, !workspace.isArchived(chat), !workspace.isTrashed(chat)
                else { continue }
                workspace.move(chat, to: folder)
            }
        }
        if !placements.isEmpty { core.chatHistory.load() }
    }

    private static func restoreVoice(
        _ backup: VoiceBackup, _ core: AppCore, _ report: inout FullBackupReport
    ) -> Int {
        let voice = core.voiceSettings
        let settings = core.settings
        if let model = backup.dictationModel { voice.dictationModel = model }
        if let flag = backup.cleanup { voice.cleanup = flag }
        if let text = backup.vocabulary { voice.vocabulary = text }
        if let languages = backup.languages { voice.languages = languages }
        if let raw = backup.appContext, let level = VoiceAppContext.Level(rawValue: raw) {
            let kept = FullBackupImportPolicy.appContext(recorded: level, current: voice.appContext)
            voice.appContext = kept.level
        }
        if let modes = backup.modes { voice.modes = modes }
        if let raw = backup.askMode, let mode = DictationMode(rawValue: raw) { voice.askMode = mode }
        if let model = backup.askModel { voice.askModel = model }
        if let id = backup.askAgent, core.agentStore.agent(id: id) != nil { voice.askAgent = id }
        if let raw = backup.dictationMode, let mode = DictationMode(rawValue: raw) {
            settings.dictationMode = mode
        }
        if let language = backup.dictationLanguage { settings.dictationLanguage = language }
        if let flag = backup.dictationAdaptsCapitalization { settings.dictationAdaptsCapitalization = flag }
        if let flag = backup.dictationLiveInsertion { settings.dictationLiveInsertion = flag }
        if let raw = backup.dictationIdleReleaseMinutes, let value = DictationIdleRelease(rawValue: raw) {
            settings.dictationIdleRelease = value
        }
        return backup.count
    }

    private static func restoreQuickActions(
        _ backup: QuickActionsBackup, mode: FullBackupImportMode, _ core: AppCore,
        _ report: inout FullBackupReport
    ) -> Int {
        let store = core.customQuickActions
        report.droppedRecords += backup.actions?.dropped ?? 0
        let plan = FullBackupMerge.plan(
            incoming: backup.actions?.items ?? [], existing: store.actions, mode: mode)
        do {
            for id in plan.removals {
                try store.remove(id: id)
                core.hotKeys.setBinding(nil, for: .quickAction(id: id))
            }
            for action in plan.upserts {
                if store.action(id: action.id) != nil {
                    try store.update(action)
                } else {
                    try store.add(action)
                }
            }
        } catch {
            report.problems.append(error.localizedDescription)
        }
        let settingsStore = core.quickActionSettings
        var settings = settingsStore.settings
        if let previews = backup.previews { settings.storedPreviewChoices = previews }
        if let language = backup.language { settings.targetLanguage = language }
        if let instructions = backup.instructions { settings.storedInstructionOverrides = instructions }
        settingsStore.settings = settings
        if let model = backup.model { settingsStore.select(model) }
        let actions =
            BuiltInQuickAction.allCases.map(QuickAction.builtIn) + store.actions.map(QuickAction.custom)
        for (id, selection) in backup.modelOverrides ?? [:] {
            guard let action = actions.first(where: { $0.id == id }) else { continue }
            settingsStore.setModelOverride(selection, for: action)
        }
        return plan.upserts.count
    }

    private static func restoreExtensions(
        _ backup: ExtensionsBackup, _ core: AppCore, _ report: inout FullBackupReport
    ) -> Int {
        let manager = core.extensions
        let items = backup.extensions?.items ?? []
        report.droppedRecords += backup.extensions?.dropped ?? 0
        report.backgroundCommands += FullBackupImportPolicy.backgroundCommands(items)
        var restored = 0
        for item in items {
            guard manager.extensionNamed(item.name) != nil else {
                report.missingExtensions.append(item.title)
                continue
            }
            for (key, value) in item.preferences ?? [:] {
                let value = FullBackupPaths.value(value, local).preferenceValue
                manager.storage.setPreference(extension: item.name, key: key, value: value)
            }
            if let appearance = item.appearance { manager.setAppearance(appearance, for: item.name) }
            restored += 1
        }
        manager.storage.flush()
        if let model = backup.aiModel { core.extensionAICoordinator.gate.settings.select(model) }
        return restored
    }

    private static func restoreMore(
        _ backup: MoreBackup, _ core: AppCore, _ report: inout FullBackupReport
    ) -> Int {
        let hotKeys = core.hotKeys
        let snippets = core.snippetsStore.snippets
        var restored = 0
        report.droppedRecords += backup.hotkeys?.dropped ?? 0
        for hotkey in backup.hotkeys?.items ?? [] {
            guard let action = action(for: hotkey, core: core, snippets: snippets) else { continue }
            guard hotKeys.conflictOwner(of: hotkey.binding, excluding: action) == nil else {
                report.takenShortcuts += 1
                continue
            }
            hotKeys.setBinding(hotkey.binding, for: action)
            restored += 1
        }
        if backup.fallbackOrder != nil || backup.disabledFallbacks != nil {
            core.fallbacks.restore(
                order: backup.fallbackOrder ?? core.fallbacks.orderedIDs,
                disabled: FullBackupImportPolicy.disabledFallbacks(
                    recorded: backup.disabledFallbacks ?? [], current: core.fallbacks.disabledIDs))
        }
        if let hidden = backup.hiddenMeetingCalendars { core.calendarStore.hiddenIDs = hidden }
        let settings = core.settings
        if let browser = backup.meetingBrowser,
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) != nil
        {
            settings.meetingBrowserBundleID = browser
        }
        if let raw = backup.screenAwarenessDestination,
            let destination = ScreenAwarenessDestination(rawValue: raw)
        {
            settings.screenAwarenessDestination = destination
        }
        if let flag = backup.agentSessionsEnabled { settings.agentSessionsEnabled = flag }
        if let terminal = backup.agentSessionsTerminal { settings.agentSessionsTerminal = terminal }
        if let flag = backup.agentStatusMenuBar { settings.agentStatusMenuBar = flag }
        return restored
    }

    private static func action(
        for hotkey: MoreBackup.Hotkey, core: AppCore, snippets: [StoredSnippet]
    ) -> HotKeyAction? {
        let uuid = hotkey.id.flatMap(UUID.init(uuidString:))
        switch hotkey.kind {
        case .dictation: return .dictation
        case .quickAction:
            return uuid.flatMap { core.customQuickActions.action(id: $0) != nil ? .quickAction(id: $0) : nil }
        case .appleShortcut: return uuid.map { .appleShortcut(id: $0) }
        case .extensionCommand:
            return hotkey.id.flatMap {
                core.extensions.launcherEntry(forEntryID: $0) != nil ? .extensionCommand(entryID: $0) : nil
            }
        case .agent: return uuid.flatMap { core.agentStore.agent(id: $0) != nil ? .agent(id: $0) : nil }
        case .snippet:
            return snippets.first { $0.snippet.name == hotkey.id }.map { .snippet(id: $0.id) }
        }
    }

    private static func restoreChats(
        _ backup: ChatHistoryBackup, layout: FullBackupLayout, _ core: AppCore,
        _ report: inout FullBackupReport
    ) async -> Int {
        let history = core.chatHistory
        // Opened first, so the database exists with its schema before rows are merged into it.
        history.load()
        var added = 0
        if FileManager.default.fileExists(atPath: layout.chatDatabaseURL.path) {
            let source = layout.chatDatabaseURL
            let target = history.databaseURL
            do {
                added = try await Task.detached(priority: .userInitiated) {
                    try FullBackupChatArchive.merge(source, into: target)
                }.value
            } catch {
                report.problems.append(error.localizedDescription)
            }
            history.load()
        }
        let store = core.agentStore
        for (rawChat, rawAgent) in backup.chatAgents ?? [:] {
            guard let chat = UUID(uuidString: rawChat), let agent = UUID(uuidString: rawAgent),
                store.agent(id: agent) != nil, store.agent(forChat: chat) == nil
            else { continue }
            store.setAgent(agent, forChat: chat)
        }
        for raw in backup.personalChats ?? [] {
            if let chat = UUID(uuidString: raw) { store.notePersonal(forChat: chat) }
        }
        for summary in layout.chatSummaries() {
            guard let chat = UUID(uuidString: String(summary.name.dropLast(".json".count))) else { continue }
            let url = store.summaryURL(forChat: chat)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? summary.data.write(to: url, options: .atomic)
        }
        return added
    }

    /// Written only for what exists here, so a key never lands beside nothing that can use it.
    private static func restoreSecrets(_ secrets: FullBackupSecrets, _ core: AppCore) -> Int {
        var restored = 0
        let ai = core.aiSettings
        func connection(_ raw: String) -> UUID? {
            UUID(uuidString: raw).flatMap { ai.connection(id: $0) != nil ? $0 : nil }
        }
        for (raw, key) in secrets.aiKeys ?? [:] {
            guard let id = connection(raw),
                (try? KeychainSecretStore.aiAPIKeys.setSecret(key, for: id)) != nil
            else { continue }
            restored += 1
        }
        for (raw, values) in secrets.aiHeaders ?? [:] {
            guard let id = connection(raw),
                (try? KeychainSecretStore.aiRequestHeaders.setValues(values, for: id)) != nil
            else { continue }
            restored += 1
        }
        for (raw, key) in secrets.openRouterManagementKeys ?? [:] {
            guard let id = connection(raw),
                (try? KeychainSecretStore.openRouterManagementKeys.setSecret(key, for: id)) != nil
            else { continue }
            restored += 1
        }
        for (raw, item) in secrets.mcp ?? [:] {
            guard let id = UUID(uuidString: raw), core.mcpSettings.server(id: id) != nil,
                (try? KeychainSecretStore.mcpSecrets.setSecret(item, for: id)) != nil
            else { continue }
            restored += 1
        }
        if let keys = secrets.webSearchKeys, !keys.isEmpty {
            let merged = ((try? core.webSearch.keys()) ?? [:]).merging(keys) { _, imported in imported }
            if (try? core.webSearch.setKeys(merged)) != nil { restored += 1 }
        }
        for (raw, values) in secrets.installedEnvironment ?? [:] {
            guard let kind = InstalledAIKind(rawValue: raw) else { continue }
            let variables = values.sorted { $0.key < $1.key }.map {
                InstalledAIVariable(name: $0.key, value: $0.value)
            }
            if (try? ai.setEnvironment(variables, for: kind)) != nil { restored += 1 }
        }
        let manager = core.extensions
        for (name, item) in secrets.extensions ?? [:] where manager.extensionNamed(name) != nil {
            for (key, value) in item.passwords ?? [:] {
                manager.storage.setPreference(extension: name, key: key, value: .string(value))
            }
            for (provider, tokens) in item.oauthTokens ?? [:] {
                manager.storage.setOAuthTokens(extension: name, provider: provider, tokens: tokens)
            }
            restored += 1
        }
        manager.storage.flush()
        return restored
    }

    private static func isOn(_ consent: FullBackupConsent, _ core: AppCore) -> Bool {
        let settings = core.settings
        let voice = core.voiceSettings
        let gate = core.extensionAICoordinator.gate.settings
        switch consent {
        case .aiEnabled: return settings.aiEnabled
        case .mcpEnabled: return settings.mcpEnabled
        case .quickActionsEnabled: return settings.quickActionsEnabled
        case .cloudDictation: return voice.cloudDictation
        case .askByVoice: return voice.askEnabled
        case .dictationEnabled: return settings.dictationEnabled
        case .dictationAppScreenshot: return voice.appContext == .screenshot
        case .screenAwarenessEnabled: return settings.screenAwarenessEnabled
        case .screenAwarenessScreenshot: return settings.screenAwarenessScreenshot
        case .extensionsEnabled: return settings.extensionsEnabled
        case .extensionsAIEnabled: return gate.isEnabled
        case .extensionsAIHonorsModels: return gate.honorsModels
        case .calendarEnabled: return settings.calendarEnabled
        case .autoJoinMeetings: return settings.autoJoinMeetings
        case .cameraPreview: return settings.cameraPreview
        case .snippetsEnabled: return settings.snippetsEnabled
        case .clipboardTextSearch: return settings.clipboardTextSearchEnabled
        case .installedAITools: return !core.aiSettings.enabledInstalledProviders.isEmpty
        case .chatFinishNotifications: return core.chatWorkspace.settings.notifiesInBackground
        }
    }
}
