import Foundation
import Observation

/// The fork's own store, so AppSettings stays upstream's; every key is an AppSettingsKey.
@MainActor
@Observable
final class VoiceAISettings {
    private typealias Key = AppSettingsKey

    @ObservationIgnored private let defaults: UserDefaults

    /// Off by default: it sends each finished recording to an AI connection.
    var cloudDictation: Bool {
        didSet { defaults.set(cloudDictation, forKey: Key.voiceCloudDictation.rawValue) }
    }
    /// nil resolves to a default through `VoiceRoutePolicy` each time it is read.
    var dictationModel: AIModelSelection? {
        didSet { persist(dictationModel, forKey: .voiceDictationModel) }
    }
    var cleanup: Bool {
        didSet { defaults.set(cleanup, forKey: Key.voiceDictationCleanup.rawValue) }
    }
    /// Words the model cannot know, such as names; the field caps it at `maxVocabularyLength`.
    var vocabulary: String {
        didSet { defaults.set(vocabulary, forKey: Key.voiceVocabulary.rawValue) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cloudDictation = defaults.bool(forKey: Key.voiceCloudDictation.rawValue)
        dictationModel = Self.selection(defaults.data(forKey: Key.voiceDictationModel.rawValue))
        cleanup = defaults.object(forKey: Key.voiceDictationCleanup.rawValue) as? Bool ?? true
        vocabulary = defaults.string(forKey: Key.voiceVocabulary.rawValue) ?? ""
    }

    private static func selection(_ data: Data?) -> AIModelSelection? {
        data.flatMap { try? JSONDecoder().decode(AIModelSelection.self, from: $0) }
    }

    private func persist(_ selection: AIModelSelection?, forKey key: AppSettingsKey) {
        guard let selection, let data = try? JSONEncoder().encode(selection) else {
            defaults.removeObject(forKey: key.rawValue)
            return
        }
        defaults.set(data, forKey: key.rawValue)
    }
}
