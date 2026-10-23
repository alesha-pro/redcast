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
    /// `DictationLanguage` raw values; until chosen, the Mac's own languages.
    var languages: [String] {
        didSet { defaults.set(languages, forKey: Key.voiceDictationLanguages.rawValue) }
    }
    var appContext: VoiceAppContext.Level {
        didSet { defaults.set(appContext.rawValue, forKey: Key.voiceDictationAppContext.rawValue) }
    }
    /// Prompts a cloud transcript passes through, the default and each app's own.
    var modes: VoiceModeSettings {
        didSet {
            guard modes != oldValue, let data = try? JSONEncoder().encode(modes) else { return }
            defaults.set(data, forKey: Key.voiceDictationModes.rawValue)
        }
    }
    /// Off by default: its shortcut records a question and reads the window in front.
    var askEnabled: Bool {
        didSet { defaults.set(askEnabled, forKey: Key.voiceAskEnabled.rawValue) }
    }
    var askMode: DictationMode {
        didSet { defaults.set(askMode.rawValue, forKey: Key.voiceAskMode.rawValue) }
    }
    var askModel: AIModelSelection? {
        didSet { persist(askModel, forKey: .voiceAskModel) }
    }
    /// nil answers with `askModel`; an agent hears the request as a background task.
    var askAgent: UUID? {
        didSet { defaults.set(askAgent?.uuidString, forKey: Key.voiceAskAgent.rawValue) }
    }

    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = SystemLanguages.preferred) {
        self.defaults = defaults
        cloudDictation = defaults.bool(forKey: Key.voiceCloudDictation.rawValue)
        dictationModel = Self.selection(defaults.data(forKey: Key.voiceDictationModel.rawValue))
        cleanup = defaults.object(forKey: Key.voiceDictationCleanup.rawValue) as? Bool ?? true
        vocabulary = defaults.string(forKey: Key.voiceVocabulary.rawValue) ?? ""
        languages = VoiceLanguagePolicy.normalized(
            defaults.stringArray(forKey: Key.voiceDictationLanguages.rawValue)
                ?? VoiceLanguagePolicy.defaults(preferred: preferredLanguages))
        appContext =
            defaults.string(forKey: Key.voiceDictationAppContext.rawValue)
            .flatMap(VoiceAppContext.Level.init(rawValue:)) ?? .title
        modes =
            defaults.data(forKey: Key.voiceDictationModes.rawValue)
            .flatMap { try? JSONDecoder().decode(VoiceModeSettings.self, from: $0) } ?? VoiceModeSettings()
        askEnabled = defaults.bool(forKey: Key.voiceAskEnabled.rawValue)
        askMode =
            defaults.string(forKey: Key.voiceAskMode.rawValue).flatMap(DictationMode.init(rawValue:))
            ?? .toggle
        askModel = Self.selection(defaults.data(forKey: Key.voiceAskModel.rawValue))
        askAgent = defaults.string(forKey: Key.voiceAskAgent.rawValue).flatMap(UUID.init(uuidString:))
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
