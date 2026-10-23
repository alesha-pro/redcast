import Foundation
import Observation

/// The agent a surface's new chats start with, by id under its own AppSettingsKey.
@MainActor
@Observable
final class AgentDefaultStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: AppSettingsKey

    /// Nil, or a value that is no id, means none; a gone agent is the reader's to ignore.
    var agentID: UUID? {
        didSet { defaults.set(agentID?.uuidString, forKey: key.rawValue) }
    }

    init(_ key: AppSettingsKey, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.key = key
        agentID = defaults.string(forKey: key.rawValue).flatMap(UUID.init(uuidString:))
    }
}
