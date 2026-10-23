import AppKit

/// Dictation History's action surface: what is recorded, the screen, its rows' actions, the file.
@MainActor
final class DictationHistoryCoordinator {
    let settings: DictationHistorySettings
    private let appSettings: AppSettings
    private let voice: VoiceAISettings
    private let voiceCloud: VoiceCloudTranscriber
    private let appIndex: AppIndex
    private let injector: TextInjector
    private let paletteCoordinator: PaletteCoordinator
    private let palette: PaletteState
    /// Dialogs and HUDs stay owned by the composition root.
    private unowned let core: AppCore

    private var builtIndex: DictationHistoryIndex?
    /// Every write waits for the one before, so a Clear issued after an append lands after it.
    private var lastWrite: Task<Void, Never>?

    init(
        appSettings: AppSettings, voice: VoiceAISettings, voiceCloud: VoiceCloudTranscriber,
        appIndex: AppIndex, injector: TextInjector, paletteCoordinator: PaletteCoordinator,
        palette: PaletteState, core: AppCore, settings: DictationHistorySettings = DictationHistorySettings()
    ) {
        self.settings = settings
        self.appSettings = appSettings
        self.voice = voice
        self.voiceCloud = voiceCloud
        self.appIndex = appIndex
        self.injector = injector
        self.paletteCoordinator = paletteCoordinator
        self.palette = palette
        self.core = core
    }

    /// Built on the first open, never at launch.
    var index: DictationHistoryIndex {
        if let builtIndex { return builtIndex }
        let index = DictationHistoryIndex()
        builtIndex = index
        return index
    }

    /// Listed while the history keeps anything and a voice feature can add to it.
    var isActive: Bool {
        settings.retention.keepsHistory
            && (appSettings.dictationEnabled || (voice.askEnabled && settings.keepsVoiceReplies))
    }

    /// Whether Ask by Voice and voice edits are being written down now.
    var keepsVoiceReplies: Bool { settings.retention.keepsHistory && settings.keepsVoiceReplies }

    /// Command visibility only; no file is read here.
    func applyEnabled() {
        appIndex.setCommandsVisible([.dictationHistory], isActive)
        guard !isActive else { return }
        builtIndex?.close()
        if palette.mode == .dictationHistory { palette.prepare(mode: .launcher) }
    }

    /// A shorter span applies to the file at once, and Off removes it.
    func setRetention(_ retention: DictationHistoryRetention) {
        guard retention != settings.retention else { return }
        settings.retention = retention
        let now = Date()
        write { DictationHistoryFile.trim(retention: retention, now: now) }
        applyEnabled()
        if let builtIndex, builtIndex.phase != .idle { builtIndex.reload(loader()) }
    }

    /// Only what comes next; replies already kept stay until they age out or are deleted.
    func setKeepsVoiceReplies(_ keeps: Bool) {
        settings.keepsVoiceReplies = keeps
        applyEnabled()
    }

    // MARK: - Recording

    /// The cloud engine says how its transcript was made; anything else was the on-device model.
    func recordDictation(text: String, transcript: String, samples: Int, target: InjectionTarget?) {
        let cloud = voiceCloud.lastTranscription.flatMap { $0.text == transcript ? $0 : nil }
        let ownEditor = target?.ownEditor != nil
        let app = target?.externalApp
        record(
            DictationHistoryEntry(
                date: Date(), kind: .dictation, text: text, transcript: cloud?.transcript, mode: cloud?.mode,
                engine: cloud == nil ? .onDevice : .cloud,
                model: cloud?.model ?? appSettings.dictationModel.title,
                appName: ownEditor ? Bundle.main.appDisplayName : app?.localizedName,
                bundleID: ownEditor ? Bundle.main.bundleIdentifier : app?.bundleIdentifier,
                duration: (Double(samples) / Double(DictationWire.sampleRate) * 10).rounded() / 10))
    }

    func record(_ entry: DictationHistoryEntry) {
        let retention = settings.retention
        guard retention.keepsHistory, entry.kind.isKept(voiceReplies: settings.keepsVoiceReplies)
        else { return }
        write { DictationHistoryFile.append(entry, retention: retention) }
        builtIndex?.insert(entry)
    }

    // MARK: - The screen

    func show() {
        guard isActive else { return }
        index.open(loader())
        paletteCoordinator.togglePalette(mode: .dictationHistory)
    }

    func screenAppeared() {
        guard isActive else { return }
        index.open(loader())
    }

    func screenDisappeared() {
        builtIndex?.close()
    }

    /// Waits for the writes already queued, so a dictation that just finished is listed.
    private func loader() -> @Sendable () async -> [DictationHistoryEntry] {
        let retention = settings.retention
        let pending = lastWrite
        return {
            await pending?.value
            return await Self.load(retention: retention)
        }
    }

    @concurrent
    private static func load(retention: DictationHistoryRetention) async -> [DictationHistoryEntry] {
        DictationHistoryFile.load(retention: retention, now: Date())
    }

    // MARK: - Actions

    /// Typed where the caret was when the palette opened, as a snippet is, with the clipboard kept.
    func paste(_ entry: DictationHistoryEntry) {
        let target = InjectionTarget.behindPalette(
            ownWindow: paletteCoordinator.previousOwnWindow, app: paletteCoordinator.targetApp)
        paletteCoordinator.hidePalette(restoreFocus: target?.ownEditor != nil)
        injector.deliver(
            InjectedText(entry.text), target: target, expectedKeyword: nil, keywordLength: 0,
            automaticGeneration: nil,
            onFailed: { [weak self] in
                self?.core.showMessage(
                    String(localized: "Couldn't paste dictation into this app"), tone: .danger)
            })
    }

    /// Unmarked, so the copy enters clipboard history like any other the reader meant to make.
    func copy(_ entry: DictationHistoryEntry) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(entry.text)
    }

    func copyTranscript(_ entry: DictationHistoryEntry) {
        guard let transcript = entry.transcript else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(transcript)
    }

    /// ⌘C, handed over by the panel before the search field, which has nothing selected to copy.
    func copySelection() -> Bool {
        guard palette.mode == .dictationHistory, let builtIndex else { return false }
        let rows = builtIndex.rows(for: palette.query)
        guard !rows.isEmpty else { return false }
        copy(rows[min(max(palette.selection, 0), rows.count - 1)])
        return true
    }

    func delete(_ entry: DictationHistoryEntry) {
        builtIndex?.remove([entry.id])
        write { DictationHistoryFile.delete([entry.id]) }
    }

    /// ⌃⇧X, the ⌘K row and Settings' Clear… all land here, so none skips the question.
    func clearHistory() async {
        guard
            await core.confirm(
                title: String(localized: "Clear dictation history?"),
                message: String(localized: "Every transcript in it is removed. This can't be undone."),
                symbol: CommandID.dictationHistory.sfSymbol, confirmTitle: String(localized: "Clear History"))
        else { return }
        builtIndex?.removeAll()
        write { DictationHistoryFile.clear() }
    }

    private func write(_ work: @escaping @Sendable () -> Void) {
        let previous = lastWrite
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
            work()
        }
    }
}
