import Foundation
import Observation

/// The fork's own store, so AppSettings stays upstream's; its keys are AppSettingsKeys.
@MainActor
@Observable
final class DictationHistorySettings {
    @ObservationIgnored private let defaults: UserDefaults

    var retention: DictationHistoryRetention {
        didSet { defaults.set(retention.rawValue, forKey: AppSettingsKey.dictationHistoryRetention.rawValue) }
    }

    /// Ask by Voice answers and voice edits; off by default, so an update never starts them.
    var keepsVoiceReplies: Bool {
        didSet {
            defaults.set(keepsVoiceReplies, forKey: AppSettingsKey.dictationHistoryVoiceReplies.rawValue)
        }
    }

    /// A failed dictation's audio, kept so its entry can be retried; on by default.
    var keepsFailedRecordings: Bool {
        didSet {
            defaults.set(
                keepsFailedRecordings, forKey: AppSettingsKey.dictationHistoryFailedRecordings.rawValue)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `integer(forKey:)` reads a missing key as 0, which is Off.
        retention =
            (defaults.object(forKey: AppSettingsKey.dictationHistoryRetention.rawValue) as? Int)
            .flatMap(DictationHistoryRetention.init(rawValue:)) ?? .standard
        keepsVoiceReplies = defaults.bool(forKey: AppSettingsKey.dictationHistoryVoiceReplies.rawValue)
        keepsFailedRecordings =
            defaults.object(forKey: AppSettingsKey.dictationHistoryFailedRecordings.rawValue) as? Bool ?? true
    }
}
