import Foundation

/// A switch that grants a capability: a file records it, an import never turns it on.
enum FullBackupConsent: String, CaseIterable, Codable, Sendable {
    case aiEnabled
    case mcpEnabled
    case quickActionsEnabled
    case cloudDictation
    case askByVoice
    case dictationEnabled
    case dictationAppScreenshot
    case screenAwarenessEnabled
    case screenAwarenessScreenshot
    case extensionsEnabled
    case extensionsAIEnabled
    case extensionsAIHonorsModels
    case calendarEnabled
    case autoJoinMeetings
    case cameraPreview
    case snippetsEnabled
    case clipboardTextSearch
    case installedAITools

    /// The key whose value it records; the coverage guard reads this list.
    var settingsKey: AppSettingsKey {
        switch self {
        case .aiEnabled: return .aiEnabled
        case .mcpEnabled: return .mcpEnabled
        case .quickActionsEnabled: return .quickActionsEnabled
        case .cloudDictation: return .voiceCloudDictation
        case .askByVoice: return .voiceAskEnabled
        case .dictationEnabled: return .dictationEnabled
        case .dictationAppScreenshot: return .voiceDictationAppContext
        case .screenAwarenessEnabled: return .screenAwarenessEnabled
        case .screenAwarenessScreenshot: return .screenAwarenessScreenshot
        case .extensionsEnabled: return .extensionsEnabled
        case .extensionsAIEnabled: return .extensionsAIEnabled
        case .extensionsAIHonorsModels: return .extensionsAIHonorsModels
        case .calendarEnabled: return .calendarEnabled
        case .autoJoinMeetings: return .autoJoinMeetings
        case .cameraPreview: return .cameraPreview
        case .snippetsEnabled: return .snippetsEnabled
        case .clipboardTextSearch: return .clipboardTextSearchEnabled
        case .installedAITools: return .aiInstalledProviders
        }
    }

    var label: String {
        switch self {
        case .aiEnabled: return String(localized: "AI")
        case .mcpEnabled: return String(localized: "MCP Servers")
        case .quickActionsEnabled: return String(localized: "Quick Actions")
        case .cloudDictation: return String(localized: "Cloud dictation")
        case .askByVoice: return String(localized: "Ask by Voice")
        case .dictationEnabled: return String(localized: "Dictation")
        case .dictationAppScreenshot: return String(localized: "Screenshots for cloud dictation")
        case .screenAwarenessEnabled: return String(localized: "Screen Awareness")
        case .screenAwarenessScreenshot: return String(localized: "Screen Awareness screenshots")
        case .extensionsEnabled: return String(localized: "Extensions")
        case .extensionsAIEnabled: return String(localized: "AI for extensions")
        case .extensionsAIHonorsModels: return String(localized: "Models extensions name")
        case .calendarEnabled: return String(localized: "Calendar")
        case .autoJoinMeetings: return String(localized: "Auto-join meetings")
        case .cameraPreview: return String(localized: "Camera preview")
        case .snippetsEnabled: return String(localized: "Snippets")
        case .clipboardTextSearch: return String(localized: "Text in clipboard images")
        case .installedAITools: return String(localized: "Installed AI tools")
        }
    }
}

/// The consents a file recorded as on; the import names those still off here.
struct FullBackupConsents: Codable, Sendable, Equatable {
    var on: [FullBackupConsent] = []

    init(_ on: [FullBackupConsent] = []) {
        self.on = on
    }

    /// Unknown names from a newer build are dropped rather than failing the section.
    init(from decoder: any Decoder) throws {
        let names = try decoder.singleValueContainer().decode([String].self)
        on = names.compactMap(FullBackupConsent.init(rawValue:))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(on.map(\.rawValue))
    }

    static func recording(_ flags: [FullBackupConsent: Bool]) -> FullBackupConsents {
        FullBackupConsents(FullBackupConsent.allCases.filter { flags[$0] == true })
    }
}
