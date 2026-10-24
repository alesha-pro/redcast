import Foundation

// Every field is optional: a file from an older build decodes, and a missing field changes nothing.

struct AgentsBackup: Codable, Sendable, Equatable {
    var agents: FullBackupList<AgentProfile>?
    var schedules: FullBackupList<AgentSchedule>?
    var scheduleCapUSD: Double?
    /// Agent id, lowercased, to the notes it keeps for later chats.
    var memories: [String: String]?
    var quickAIAgent: UUID?
    var chatAgent: UUID?

    var count: Int { agents?.items.count ?? 0 }
}

struct MCPBackup: Codable, Sendable, Equatable {
    /// Each server as it was, `isEnabled` included; the import turns every one off.
    var servers: FullBackupList<MCPServer>?
    var consents: FullBackupConsents?

    var count: Int { servers?.items.count ?? 0 }
}

struct AIBackup: Codable, Sendable, Equatable {
    var connections: FullBackupList<AIConnection>?
    var defaultModel: AIModelSelection?
    var webSearch: Bool?
    var choices: Bool?
    var systemPrompt: String?
    var systemPromptEnabled: Bool?
    var retentionDays: Int?
    var opensTo: Int?
    var newChatAfterMinutes: Int?
    var toolRounds: Int?
    var shownModels: [String: [String]]?
    var disabledRoutes: [String]?
    /// Recorded for the summary only: discovering an installed CLI runs it.
    var installedProviders: [String]?
    var installedOverrides: [String: InstalledAIOverride]?
    var webSearchEngines: WebSearchConfiguration?
    var consents: FullBackupConsents?

    var count: Int { connections?.items.count ?? 0 }
}

struct VoiceBackup: Codable, Sendable, Equatable {
    var dictationModel: AIModelSelection?
    var cleanup: Bool?
    var vocabulary: String?
    var languages: [String]?
    var appContext: String?
    var modes: VoiceModeSettings?
    var askMode: String?
    var askModel: AIModelSelection?
    var askAgent: UUID?
    var dictationMode: String?
    var dictationLanguage: String?
    var dictationAdaptsCapitalization: Bool?
    var dictationLiveInsertion: Bool?
    var dictationIdleReleaseMinutes: Int?
    var consents: FullBackupConsents?

    var count: Int { modes?.custom.count ?? 0 }
}

struct QuickActionsBackup: Codable, Sendable, Equatable {
    var actions: FullBackupList<CustomQuickAction>?
    var previews: [String: Bool]?
    var language: String?
    var instructions: [String: String]?
    var model: AIModelSelection?
    /// Keyed by `QuickAction.id`, so a custom action's override follows it by its id.
    var modelOverrides: [String: AIModelSelection]?
    var consents: FullBackupConsents?

    var count: Int { actions?.items.count ?? 0 }
}

struct ExtensionsBackup: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable {
        var name: String
        var title: String
        var author: String
        var owner: String?
        var commitSHA: String?
        /// Password preferences never land here; they travel only in the sealed secrets.
        var preferences: [String: FullBackupValue]?
        var appearance: ExtensionAppearance?
        /// Recorded for the summary: a background or menu-bar command runs code unasked.
        var backgroundCommands: [String]?
        var menuBarCommands: [String]?
    }

    var extensions: FullBackupList<Item>?
    var aiModel: AIModelSelection?
    var consents: FullBackupConsents?

    var count: Int { extensions?.items.count ?? 0 }
}

/// Shortcut kinds upstream's settings payload leaves out, plus the smaller stores beside them.
struct MoreBackup: Codable, Sendable, Equatable {
    struct Hotkey: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable {
            case dictation
            case quickAction
            case appleShortcut
            case extensionCommand
            case agent
            /// By the snippet's name: its id is a path on the Mac that wrote it.
            case snippet
        }

        var kind: Kind
        var id: String?
        var binding: HotKeyBinding
    }

    var hotkeys: FullBackupList<Hotkey>?
    var fallbackOrder: [String]?
    var disabledFallbacks: [String]?
    var hiddenMeetingCalendars: [String]?
    var meetingBrowser: String?
    var screenAwarenessDestination: String?
    var agentSessionsEnabled: Bool?
    var agentSessionsTerminal: String?
    var agentStatusMenuBar: Bool?
    var consents: FullBackupConsents?

    var count: Int { hotkeys?.items.count ?? 0 }
}

/// The chat database travels as its own SQLite file beside this; here are the agent links.
struct ChatHistoryBackup: Codable, Sendable, Equatable {
    var conversations: Int?
    /// Chat id to agent id, both lowercased.
    var chatAgents: [String: String]?
    var personalChats: [String]?

    var count: Int { conversations ?? 0 }
}

/// What the sealed blob holds, keyed by the ids the stores use; decrypted only on import.
struct FullBackupSecrets: Codable, Sendable, Equatable {
    struct ExtensionSecrets: Codable, Sendable, Equatable {
        var passwords: [String: String]?
        var oauthTokens: [String: String]?
    }

    /// AI connection id to its API key.
    var aiKeys: [String: String]?
    var aiHeaders: [String: [String: String]]?
    var openRouterManagementKeys: [String: String]?
    /// MCP server id to its Keychain item, verbatim: header, environment, OAuth client and token.
    var mcp: [String: String]?
    var webSearchKeys: [String: String]?
    /// `InstalledAIKind` raw value to its environment variables.
    var installedEnvironment: [String: [String: String]]?
    var extensions: [String: ExtensionSecrets]?

    var count: Int {
        (aiKeys?.count ?? 0) + (aiHeaders?.count ?? 0) + (openRouterManagementKeys?.count ?? 0)
            + (mcp?.count ?? 0) + (webSearchKeys?.isEmpty == false ? 1 : 0)
            + (installedEnvironment?.count ?? 0) + (extensions?.count ?? 0)
    }
}
