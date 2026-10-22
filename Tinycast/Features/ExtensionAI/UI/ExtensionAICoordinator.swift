import AppKit
import Foundation

/// Answers an extension's `AI.ask` with the model chosen for extensions, once the user allows it.
@MainActor
final class ExtensionAICoordinator: ExtensionAIHost {
    private unowned let core: AppCore
    private(set) lazy var settings = ExtensionAISettingsStore()
    private let bridge = ExtensionAIBridge()
    private var rateLimit = ExtensionAIRateLimit()
    /// One dialog per extension, however many of its asks arrive while it is up.
    private var consents: [String: Task<Bool, Never>] = [:]

    init(core: AppCore) {
        self.core = core
    }

    // MARK: - ExtensionAIHost

    func perform(
        method: String, arguments: [RenderValue], extensionName: String,
        launchType: ExtensionLaunchType, owner: ObjectIdentifier
    ) async throws -> Any? {
        switch method {
        case "start":
            let prompt = arguments.first?.objectValue?["prompt"]?.stringValue ?? ""
            return try await start(
                prompt: prompt, extensionName: extensionName, launchType: launchType, owner: owner)
        case "read":
            let id = streamID(arguments)
            if case .refused(let refusal) = access(extensionName, launchType: launchType) {
                bridge.cancel(id, owner: owner)
                throw refusal
            }
            return try await bridge.read(id, owner: owner)
        case "cancel":
            bridge.cancel(streamID(arguments), owner: owner)
            return nil
        default:
            throw ExtensionHostError.unknown("ai.\(method)")
        }
    }

    /// Runs at every launch, so it only reads: a dangling pick is repaired by the Settings section.
    func canAccess(extensionName: String) -> Bool {
        if case .refused = access(extensionName, launchType: .userInitiated) { return false }
        return selection() != nil
    }

    func sessionEnded(owner: ObjectIdentifier) {
        bridge.cancelAll(owner: owner)
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        if !enabled { bridge.cancelAll() }
    }

    func repairModel() {
        guard let model = settings.model,
            ExtensionAIPolicy.isDangling(model, connections: core.aiSettings.connections)
        else { return }
        settings.select(nil)
    }

    func forget(entryIDs: [String]) {
        settings.forget(Set(entryIDs.compactMap { ExtensionCommandRef(entryID: $0)?.extensionName }))
    }

    func modelTitle() -> String {
        let chat = core.aiChatCoordinator
        return chat.modelTitle(of: selection(), among: chat.modelOptions)
    }

    // MARK: - Asking

    private func start(
        prompt raw: String, extensionName name: String, launchType: ExtensionLaunchType,
        owner: ObjectIdentifier
    ) async throws -> Int {
        let prompt = try ExtensionAIPolicy.prompt(from: raw)
        let gate = access(name, launchType: launchType)
        if case .refused(let refusal) = gate { throw refusal }
        guard selection() != nil else { throw ExtensionAIRefusal.noModel }
        if gate == .ask {
            guard await consent(for: name) else { throw ExtensionAIRefusal.denied }
            try Task.checkCancellation()
            if case .refused(let refusal) = access(name, launchType: launchType) { throw refusal }
        }
        guard let selection = selection() else { throw ExtensionAIRefusal.noModel }
        let provider = try AIProviderFactory.make(
            selection: selection, settings: core.aiSettings, subscription: core.chatGPTSubscription,
            installedAI: core.installedAI)
        if let wait = rateLimit.admit(name, at: Date()) {
            throw ExtensionAIRefusal.rateLimited(seconds: max(1, Int(wait.rounded(.up))))
        }
        return bridge.start(ExtensionAIPolicy.request(prompt: prompt), on: provider, owner: owner)
    }

    private func access(_ name: String, launchType: ExtensionLaunchType) -> ExtensionAIAccess {
        ExtensionAIPolicy.access(
            featureOn: settings.isEnabled, aiOn: core.settings.aiEnabled, launchType: launchType,
            grant: settings.grants[name])
    }

    private func selection() -> AIModelSelection? {
        let chosen = settings.model.flatMap {
            ExtensionAIPolicy.isDangling($0, connections: core.aiSettings.connections) ? nil : $0
        }
        return chosen ?? core.aiSettings.defaultModel
    }

    private func streamID(_ arguments: [RenderValue]) -> Int {
        arguments.first?.doubleValue.flatMap(Int.init(exactly:)) ?? 0
    }

    /// Both answers are kept, so Escape counts as Don't Allow until changed in Settings.
    private func consent(for name: String) async -> Bool {
        if let pending = consents[name] { return await pending.value }
        let asking = Task {
            let allowed = await askConsent(for: name)
            settings.setGrant(allowed, for: name)
            consents[name] = nil
            return allowed
        }
        consents[name] = asking
        return await asking.value
    }

    /// The dialog outranks the palette, so a view command keeps its screen behind it.
    private func askConsent(for name: String) async -> Bool {
        let title = core.extensions.installed.first { $0.manifest.name == name }?.title ?? name
        NSApp.activate(ignoringOtherApps: true)
        return await core.confirm(
            title: String(localized: "Allow \u{201C}\(title)\u{201D} to use AI?"),
            message: String(
                localized: """
                    Its prompts go to \(modelTitle()) and can include text the extension reads, such \
                    as your selection or clipboard. You can change this in Settings \u{2192} Extensions.
                    """),
            symbol: "sparkles", confirmTitle: String(localized: "Allow"), tone: .neutral,
            confirmRole: .standard, dismissTitle: String(localized: "Don't Allow"))
    }
}
