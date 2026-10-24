import Foundation
import Observation

/// Fork: the AI Chat window's own preferences and remembered layout; its keys are per Mac.
@MainActor
@Observable
final class ChatWorkspaceSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var autoArchive: ChatAutoArchive {
        didSet { defaults.set(autoArchive.rawValue, forKey: AppSettingsKey.aiChatAutoArchive.rawValue) }
    }

    /// Off by default; turning it on is what asks macOS for permission, never before.
    var notifiesInBackground: Bool {
        didSet {
            defaults.set(notifiesInBackground, forKey: AppSettingsKey.aiChatFinishNotifications.rawValue)
        }
    }

    /// Window layout, not a preference: remembered like the split view's widths.
    var showsInspector: Bool {
        didSet { defaults.set(showsInspector, forKey: Self.inspectorKey) }
    }

    var floatsOnTop: Bool {
        didSet { defaults.set(floatsOnTop, forKey: Self.floatsKey) }
    }

    private static let inspectorKey = "AIChatShowsSettingsSidebar"
    private static let floatsKey = "AIChatFloatsOnTop"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoArchive =
            (defaults.object(forKey: AppSettingsKey.aiChatAutoArchive.rawValue) as? Int)
            .flatMap(ChatAutoArchive.init(rawValue:)) ?? .never
        notifiesInBackground = defaults.bool(forKey: AppSettingsKey.aiChatFinishNotifications.rawValue)
        showsInspector = defaults.object(forKey: Self.inspectorKey) as? Bool ?? true
        floatsOnTop = defaults.bool(forKey: Self.floatsKey)
    }
}
