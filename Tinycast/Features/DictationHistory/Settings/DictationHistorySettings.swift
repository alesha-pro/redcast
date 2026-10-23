import Foundation
import Observation

/// The fork's own store, so AppSettings stays upstream's; its key is an AppSettingsKey.
@MainActor
@Observable
final class DictationHistorySettings {
    @ObservationIgnored private let defaults: UserDefaults

    var retention: DictationHistoryRetention {
        didSet { defaults.set(retention.rawValue, forKey: AppSettingsKey.dictationHistoryRetention.rawValue) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `integer(forKey:)` reads a missing key as 0, which is Off.
        retention =
            (defaults.object(forKey: AppSettingsKey.dictationHistoryRetention.rawValue) as? Int)
            .flatMap(DictationHistoryRetention.init(rawValue:)) ?? .standard
    }
}
