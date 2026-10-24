import Foundation

/// Live stores → section payloads, read on the main actor where every store lives.
@MainActor
enum FullBackupGather {
    private static var portable: (String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return { FullBackupPaths.portable($0, home: home) }
    }

    static func agents(from core: AppCore) -> AgentsBackup {
        let store = core.agentStore
        var memories: [String: String] = [:]
        for agent in store.agents {
            if let notes = try? String(contentsOf: store.memoryURL(for: agent.id), encoding: .utf8) {
                memories[agent.id.uuidString.lowercased()] = notes
            }
        }
        return AgentsBackup(
            agents: FullBackupList(store.agents.map { FullBackupPaths.agent($0, portable) }),
            schedules: FullBackupList(store.schedules),
            scheduleCapUSD: store.scheduleSpend.capUSD, memories: memories,
            quickAIAgent: core.agentCoordinator.quickAIDefault.agentID,
            chatAgent: core.agentCoordinator.chatDefault.agentID)
    }

    static func mcp(from core: AppCore) -> MCPBackup {
        MCPBackup(
            servers: FullBackupList(
                core.mcpSettings.servers.map { FullBackupPaths.server($0, portable) }),
            consents: .recording([.mcpEnabled: core.settings.mcpEnabled]))
    }

    static func ai(from core: AppCore) -> AIBackup {
        let ai = core.aiSettings
        return AIBackup(
            connections: FullBackupList(ai.connections), defaultModel: ai.defaultModel,
            webSearch: ai.webSearchEnabled, choices: ai.choicesEnabled, systemPrompt: ai.systemPrompt,
            systemPromptEnabled: ai.systemPromptEnabled, retentionDays: ai.retention.rawValue,
            opensTo: ai.opensTo.rawValue, newChatAfterMinutes: ai.newChatAfter.rawValue,
            toolRounds: ai.toolRounds.rawValue, shownModels: ai.shownModels,
            disabledRoutes: ai.disabledRoutes.sorted(),
            installedProviders: ai.enabledInstalledProviders.map(\.rawValue).sorted(),
            installedOverrides: Dictionary(
                uniqueKeysWithValues: ai.installedOverrides.map {
                    ($0.key.rawValue, FullBackupPaths.override($0.value, portable))
                }),
            webSearchEngines: core.webSearch.configuration,
            consents: .recording([
                .aiEnabled: core.settings.aiEnabled,
                .installedAITools: !ai.enabledInstalledProviders.isEmpty
            ]))
    }

    static func voice(from core: AppCore) -> VoiceBackup {
        let voice = core.voiceSettings
        let settings = core.settings
        return VoiceBackup(
            dictationModel: voice.dictationModel, cleanup: voice.cleanup, vocabulary: voice.vocabulary,
            languages: voice.languages, appContext: voice.appContext.rawValue, modes: voice.modes,
            askMode: voice.askMode.rawValue, askModel: voice.askModel, askAgent: voice.askAgent,
            dictationMode: settings.dictationMode.rawValue, dictationLanguage: settings.dictationLanguage,
            dictationAdaptsCapitalization: settings.dictationAdaptsCapitalization,
            dictationLiveInsertion: settings.dictationLiveInsertion,
            dictationIdleReleaseMinutes: settings.dictationIdleRelease.rawValue,
            consents: .recording([
                .cloudDictation: voice.cloudDictation, .askByVoice: voice.askEnabled,
                .dictationEnabled: settings.dictationEnabled,
                .dictationAppScreenshot: voice.appContext == .screenshot
            ]))
    }

    static func quickActions(from core: AppCore) -> QuickActionsBackup {
        let store = core.quickActionSettings
        return QuickActionsBackup(
            actions: FullBackupList(core.customQuickActions.actions),
            previews: store.settings.storedPreviewChoices, language: store.settings.targetLanguage,
            instructions: store.settings.storedInstructionOverrides, model: store.model,
            modelOverrides: store.modelOverrides,
            consents: .recording([.quickActionsEnabled: core.settings.quickActionsEnabled]))
    }

    static func extensions(
        from core: AppCore
    ) -> (payload: ExtensionsBackup, secrets: [String: FullBackupSecrets.ExtensionSecrets]) {
        let manager = core.extensions
        let commits = storeCommits()
        var items: [ExtensionsBackup.Item] = []
        var secrets: [String: FullBackupSecrets.ExtensionSecrets] = [:]
        for owner in manager.installed {
            let name = owner.manifest.name
            let schemas = owner.manifest.preferences + owner.manifest.commands.flatMap(\.preferences)
            var preferences: [String: FullBackupValue] = [:]
            var passwords: [String: String] = [:]
            for schema in schemas {
                guard let value = manager.storage.preference(extension: name, key: schema.name) else {
                    continue
                }
                if schema.kind == .password {
                    passwords[schema.name] = value.stringValue
                } else {
                    preferences[schema.name] = FullBackupPaths.value(FullBackupValue(value), portable)
                }
            }
            let tokens = manager.storage.allOAuthTokens(extension: name)
            if !passwords.isEmpty || !tokens.isEmpty {
                secrets[name] = .init(
                    passwords: passwords.isEmpty ? nil : passwords,
                    oauthTokens: tokens.isEmpty ? nil : tokens)
            }
            let commands = owner.manifest.commands
            items.append(
                ExtensionsBackup.Item(
                    name: name, title: owner.title, author: owner.manifest.author,
                    owner: owner.manifest.owner, commitSHA: commits[name],
                    preferences: preferences.isEmpty ? nil : preferences,
                    appearance: manager.appearances.appearance(for: name),
                    backgroundCommands: commands.filter {
                        manager.backgroundInfo(extension: name, command: $0.name).backgroundEnabled
                    }.map(\.title),
                    menuBarCommands: commands.filter {
                        manager.menuBarIsEnabled(.init(extensionName: name, commandName: $0.name))
                    }.map(\.title)))
        }
        let gate = core.extensionAICoordinator.gate.settings
        let payload = ExtensionsBackup(
            extensions: FullBackupList(items), aiModel: gate.model,
            consents: .recording([
                .extensionsEnabled: core.settings.extensionsEnabled,
                .extensionsAIEnabled: gate.isEnabled, .extensionsAIHonorsModels: gate.honorsModels
            ]))
        return (payload, secrets)
    }

    static func more(from core: AppCore) -> MoreBackup {
        let hotKeys = core.hotKeys
        var hotkeys: [MoreBackup.Hotkey] = []
        func add(_ kind: MoreBackup.Hotkey.Kind, _ id: String?, _ action: HotKeyAction) {
            guard let binding = hotKeys.binding(for: action) else { return }
            hotkeys.append(.init(kind: kind, id: id, binding: binding))
        }
        add(.dictation, nil, .dictation)
        for id in hotKeys.boundQuickActionIDs { add(.quickAction, id.uuidString, .quickAction(id: id)) }
        for id in hotKeys.boundAppleShortcutIDs {
            add(.appleShortcut, id.uuidString, .appleShortcut(id: id))
        }
        for id in hotKeys.boundExtensionCommandEntryIDs {
            add(.extensionCommand, id, .extensionCommand(entryID: id))
        }
        for id in hotKeys.boundAgentIDs { add(.agent, id.uuidString, .agent(id: id)) }
        let snippets = core.snippetsStore.snippets
        for id in hotKeys.boundSnippetIDs {
            guard let snippet = snippets.first(where: { $0.id == id }) else { continue }
            add(.snippet, snippet.snippet.name, .snippet(id: id))
        }
        let settings = core.settings
        return MoreBackup(
            hotkeys: FullBackupList(hotkeys),
            fallbackOrder: core.fallbacks.orderedIDs, disabledFallbacks: core.fallbacks.disabledIDs.sorted(),
            hiddenMeetingCalendars: core.calendarStore.hiddenIDs,
            meetingBrowser: settings.meetingBrowserBundleID,
            screenAwarenessDestination: settings.screenAwarenessDestination.rawValue,
            agentSessionsEnabled: settings.agentSessionsEnabled,
            agentSessionsTerminal: settings.agentSessionsTerminal,
            agentStatusMenuBar: settings.agentStatusMenuBar,
            consents: .recording([
                .screenAwarenessEnabled: settings.screenAwarenessEnabled,
                .screenAwarenessScreenshot: settings.screenAwarenessScreenshot,
                .calendarEnabled: settings.calendarEnabled, .autoJoinMeetings: settings.autoJoinMeetings,
                .cameraPreview: settings.cameraPreview, .snippetsEnabled: settings.snippetsEnabled,
                .clipboardTextSearch: settings.clipboardTextSearchEnabled
            ]))
    }

    static func chatHistory(from core: AppCore) -> ChatHistoryBackup {
        let store = core.agentStore
        return ChatHistoryBackup(
            conversations: core.chatHistory.conversations.count,
            chatAgents: Dictionary(
                uniqueKeysWithValues: store.chatAgents.map {
                    ($0.key.uuidString.lowercased(), $0.value.uuidString.lowercased())
                }),
            personalChats: store.personalChats.map { $0.uuidString.lowercased() }.sorted())
    }

    /// Read only with the opt-in on: the one time this app reads its Keychain items to export them.
    static func secrets(
        from core: AppCore, extensions: [String: FullBackupSecrets.ExtensionSecrets]
    ) -> FullBackupSecrets {
        var secrets = FullBackupSecrets()
        var keys: [String: String] = [:]
        var headers: [String: [String: String]] = [:]
        var management: [String: String] = [:]
        for connection in core.aiSettings.connections {
            let id = connection.id
            if let key = try? KeychainSecretStore.aiAPIKeys.secret(for: id) { keys[id.uuidString] = key }
            if let values = try? KeychainSecretStore.aiRequestHeaders.values(for: id), !values.isEmpty {
                headers[id.uuidString] = values
            }
            if let key = try? KeychainSecretStore.openRouterManagementKeys.secret(for: id) {
                management[id.uuidString] = key
            }
        }
        var mcp: [String: String] = [:]
        for server in core.mcpSettings.servers {
            if let item = try? KeychainSecretStore.mcpSecrets.secret(for: server.id) {
                mcp[server.id.uuidString] = item
            }
        }
        var environment: [String: [String: String]] = [:]
        for kind in InstalledAIKind.allCases {
            guard let variables = try? core.aiSettings.environment(for: kind), !variables.isEmpty else {
                continue
            }
            environment[kind.rawValue] = Dictionary(
                variables.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
        }
        secrets.aiKeys = keys.isEmpty ? nil : keys
        secrets.aiHeaders = headers.isEmpty ? nil : headers
        secrets.openRouterManagementKeys = management.isEmpty ? nil : management
        secrets.mcp = mcp.isEmpty ? nil : mcp
        if let web = try? core.webSearch.keys(), !web.isEmpty { secrets.webSearchKeys = web }
        secrets.installedEnvironment = environment.isEmpty ? nil : environment
        secrets.extensions = extensions.isEmpty ? nil : extensions
        return secrets
    }

    /// The Store's commit per extension, read from its file: the store that owns it is private.
    private static func storeCommits() -> [String: String] {
        struct Entry: Decodable { var commitSHA: String? }
        guard let data = try? Data(contentsOf: ExtensionCatalog.storeVersionsFile()),
            let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return entries.compactMapValues(\.commitSHA)
    }
}

extension FullBackupValue {
    init(_ value: ExtensionPreferenceValue) {
        switch value {
        case .string(let text): self = .string(text)
        case .bool(let flag): self = .bool(flag)
        case .number(let number): self = .number(number)
        case .application(let path): self = .application(path)
        }
    }

    var preferenceValue: ExtensionPreferenceValue {
        switch self {
        case .string(let text): return .string(text)
        case .bool(let flag): return .bool(flag)
        case .number(let number): return .number(number)
        case .application(let path): return .application(path)
        }
    }
}
