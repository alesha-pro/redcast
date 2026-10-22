import Foundation
import Observation

/// The switches, the model and each extension's answer; none travels in a backup or settings.json.
@MainActor
@Observable
final class ExtensionAISettingsStore {
    private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: AppSettingsKey.extensionsAIEnabled.rawValue) }
    }
    /// Off by default: on, an extension's named model can move its prompts to another connection.
    var honorsModels: Bool {
        didSet { defaults.set(honorsModels, forKey: AppSettingsKey.extensionsAIHonorsModels.rawValue) }
    }
    /// Nil follows AI Chat's default model, including a later change to it.
    private(set) var model: AIModelSelection? {
        didSet { persistModel() }
    }
    /// Keyed by manifest name: true allowed, false refused; absent means ask on first use.
    private(set) var grants: [String: Bool] {
        didSet { persistGrants() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: AppSettingsKey.extensionsAIEnabled.rawValue)
        honorsModels = defaults.bool(forKey: AppSettingsKey.extensionsAIHonorsModels.rawValue)
        model = defaults.data(forKey: AppSettingsKey.extensionsAIModel.rawValue).flatMap {
            try? JSONDecoder().decode(AIModelSelection.self, from: $0)
        }
        grants =
            defaults.dictionary(forKey: AppSettingsKey.extensionsAIGrants.rawValue) as? [String: Bool]
            ?? [:]
    }

    func select(_ selection: AIModelSelection?) {
        model = selection
    }

    func setGrant(_ allowed: Bool?, for extensionName: String) {
        guard grants[extensionName] != allowed else { return }
        grants[extensionName] = allowed
    }

    func forget(_ extensionNames: Set<String>) {
        let kept = grants.filter { !extensionNames.contains($0.key) }
        if kept != grants { grants = kept }
    }

    func forgetAll() {
        grants = [:]
    }

    private func persistModel() {
        guard let model, let data = try? JSONEncoder().encode(model) else {
            defaults.removeObject(forKey: AppSettingsKey.extensionsAIModel.rawValue)
            return
        }
        defaults.set(data, forKey: AppSettingsKey.extensionsAIModel.rawValue)
    }

    private func persistGrants() {
        let key = AppSettingsKey.extensionsAIGrants.rawValue
        if grants.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(grants, forKey: key)
        }
    }
}
