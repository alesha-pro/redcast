import Foundation
import Observation

/// Quick AI's own preference beside upstream's AI store; its key is an AppSettingsKey.
@MainActor
@Observable
final class QuickAISettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    /// The agent a new Quick AI chat answers with; nil, gone or one on its own CLI means none.
    var agentID: UUID? {
        didSet { defaults.set(agentID?.uuidString, forKey: AppSettingsKey.aiQuickAIAgent.rawValue) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        agentID = defaults.string(forKey: AppSettingsKey.aiQuickAIAgent.rawValue)
            .flatMap(UUID.init(uuidString:))
    }
}
