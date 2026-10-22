import Foundation

/// Every `ai.*` call an extension makes: the gates, its one question, the route and the limit.
@MainActor
final class ExtensionAIGate: ExtensionAIHost {
    enum GateError: LocalizedError {
        case unknownCall(String)

        var errorDescription: String? {
            switch self {
            case .unknownCall(let method): "Unknown host call 'ai.\(method)'."
            }
        }
    }

    private(set) lazy var settings = ExtensionAISettingsStore(defaults: defaults)
    private let defaults: UserDefaults
    private let aiSettings: AISettingsStore
    private let aiEnabled: @MainActor () -> Bool
    /// The button the user chose, or nil when the question was dismissed or could not be shown.
    private let ask: @MainActor (_ extensionName: String) async -> Bool?
    private let makeProvider: @MainActor (AIModelSelection) throws -> any AIProvider
    private let bridge = ExtensionAIBridge()
    private var rateLimit = ExtensionAIRateLimit()
    /// One question per extension, however many of its asks arrive while it is up.
    private var questions: [String: Task<Bool?, Never>] = [:]

    init(
        defaults: UserDefaults = .standard, aiSettings: AISettingsStore,
        aiEnabled: @escaping @MainActor () -> Bool,
        ask: @escaping @MainActor (_ extensionName: String) async -> Bool?,
        makeProvider: @escaping @MainActor (AIModelSelection) throws -> any AIProvider
    ) {
        self.defaults = defaults
        self.aiSettings = aiSettings
        self.aiEnabled = aiEnabled
        self.ask = ask
        self.makeProvider = makeProvider
    }

    var isIdle: Bool { bridge.isIdle }

    // MARK: - ExtensionAIHost

    func perform(
        method: String, arguments: [RenderValue], extensionName: String, openedByUser: Bool,
        owner: ObjectIdentifier
    ) async throws -> Any? {
        switch method {
        case "start":
            let prompt = arguments.first?.objectValue?["prompt"]?.stringValue ?? ""
            return try await start(
                prompt: prompt, extensionName: extensionName, openedByUser: openedByUser, owner: owner)
        case "read":
            let id = streamID(arguments)
            if case .refused(let refusal) = access(extensionName, openedByUser: openedByUser) {
                bridge.cancel(id, owner: owner)
                throw refusal
            }
            return try await bridge.read(id, owner: owner)
        case "cancel":
            bridge.cancel(streamID(arguments), owner: owner)
            return nil
        default:
            throw GateError.unknownCall(method)
        }
    }

    /// Runs at every launch, so it only reads: a dangling pick is repaired by the Settings section.
    func canAccess(extensionName: String) -> Bool {
        if case .refused = access(extensionName, openedByUser: true) { return false }
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

    /// The pick for extensions unless its connection or model was deleted, else AI Chat's default.
    func selection() -> AIModelSelection? {
        let chosen = settings.model.flatMap {
            ExtensionAIPolicy.isDangling($0, connections: aiSettings.connections) ? nil : $0
        }
        return chosen ?? aiSettings.defaultModel
    }

    // MARK: - Asking

    private func start(
        prompt raw: String, extensionName name: String, openedByUser: Bool, owner: ObjectIdentifier
    ) async throws -> Int {
        let prompt = try ExtensionAIPolicy.prompt(from: raw)
        let gate = access(name, openedByUser: openedByUser)
        if case .refused(let refusal) = gate { throw refusal }
        guard selection() != nil else { throw ExtensionAIRefusal.noModel }
        if gate == .ask {
            switch await answer(for: name) {
            case true?: break
            case false?: throw ExtensionAIRefusal.denied
            case nil: throw ExtensionAIRefusal.unanswered
            }
            try Task.checkCancellation()
            if case .refused(let refusal) = access(name, openedByUser: openedByUser) { throw refusal }
        }
        guard let selection = selection() else { throw ExtensionAIRefusal.noModel }
        let provider = try makeProvider(selection)
        if let wait = rateLimit.admit(name, at: Date()) {
            throw ExtensionAIRefusal.rateLimited(seconds: max(1, Int(wait.rounded(.up))))
        }
        return bridge.start(ExtensionAIPolicy.request(prompt: prompt), on: provider, owner: owner)
    }

    private func access(_ name: String, openedByUser: Bool) -> ExtensionAIAccess {
        ExtensionAIPolicy.access(
            featureOn: settings.isEnabled, aiOn: aiEnabled(), openedByUser: openedByUser,
            grant: settings.grants[name])
    }

    private func streamID(_ arguments: [RenderValue]) -> Int {
        arguments.first?.doubleValue.flatMap(Int.init(exactly:)) ?? 0
    }

    /// Only a chosen button is kept: a question dismissed or never shown asks again next time.
    private func answer(for name: String) async -> Bool? {
        if let pending = questions[name] { return await pending.value }
        let asking = Task {
            let answer = await ask(name)
            if let answer { settings.setGrant(answer, for: name) }
            questions[name] = nil
            return answer
        }
        questions[name] = asking
        return await asking.value
    }
}
