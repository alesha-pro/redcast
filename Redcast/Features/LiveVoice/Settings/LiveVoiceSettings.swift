import Foundation
import Observation

/// Live Voice's persisted preferences; every key is an `AppSettingsKey` outside `settings.json`.
@MainActor
@Observable
final class LiveVoiceSettings {
    private typealias Key = AppSettingsKey

    @ObservationIgnored private let defaults: UserDefaults

    /// Off by default: streams microphone audio in real time to the consented AI connection.
    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Key.liveVoiceEnabled.rawValue) }
    }
    var model: AIModelSelection? {
        didSet { persist(model, forKey: .liveVoiceModel) }
    }
    /// Nil uses the provider's default voice.
    var voice: String? {
        didSet { defaults.set(voice, forKey: Key.liveVoiceVoice.rawValue) }
    }
    /// Nil runs as Redcast without an agent's persona, memory or background task runner.
    var agent: UUID? {
        didSet { defaults.set(agent?.uuidString, forKey: Key.liveVoiceAgent.rawValue) }
    }
    var screenMode: LiveVoiceScreenMode {
        didSet { defaults.set(screenMode.rawValue, forKey: Key.liveVoiceScreenMode.rawValue) }
    }
    /// Nil turns `point_at` off; when set, pointing uses only this consented connection and model.
    var locatorModel: AIModelSelection? {
        didSet { persist(locatorModel, forKey: .liveVoiceLocatorModel) }
    }
    var audioMode: LiveVoiceAudioMode {
        didSet { defaults.set(audioMode.rawValue, forKey: Key.liveVoiceAudioMode.rawValue) }
    }
    var effort: LiveVoiceEffort {
        didSet { defaults.set(effort.rawValue, forKey: Key.liveVoiceEffort.rawValue) }
    }
    /// Nil follows the system language, `"auto"` leaves language to the model, else an ISO code.
    var language: String? {
        didSet { defaults.set(language, forKey: Key.liveVoiceLanguage.rawValue) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Key.liveVoiceEnabled.rawValue)
        model = Self.selection(defaults.data(forKey: Key.liveVoiceModel.rawValue))
        voice = defaults.string(forKey: Key.liveVoiceVoice.rawValue)
        agent = defaults.string(forKey: Key.liveVoiceAgent.rawValue).flatMap(UUID.init(uuidString:))
        screenMode =
            defaults.string(forKey: Key.liveVoiceScreenMode.rawValue)
            .flatMap(LiveVoiceScreenMode.init(rawValue:)) ?? .everyTurn
        locatorModel = Self.selection(defaults.data(forKey: Key.liveVoiceLocatorModel.rawValue))
        audioMode =
            defaults.string(forKey: Key.liveVoiceAudioMode.rawValue)
            .flatMap(LiveVoiceAudioMode.init(rawValue:)) ?? .automatic
        effort =
            defaults.string(forKey: Key.liveVoiceEffort.rawValue)
            .flatMap(LiveVoiceEffort.init(rawValue:)) ?? .minimal
        language = defaults.string(forKey: Key.liveVoiceLanguage.rawValue)
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
