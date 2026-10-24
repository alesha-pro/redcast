import AppKit

/// Dictation History's action surface: what is recorded, the screen, its rows' actions, the file.
@MainActor
final class DictationHistoryCoordinator {
    /// What a retry transcribes with: a cloud route or a model on this Mac.
    enum RetryEngine: Equatable {
        case cloud(AIModelSelection)
        case onDevice(DictationModel)
    }

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
    /// Only while the screen is open: closing it cancels every retry still running.
    private var retries: [UUID: Task<Void, Never>] = [:]

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
        cancelRetries()
        builtIndex?.close()
        if palette.mode == .dictationHistory { palette.prepare(mode: .launcher) }
    }

    /// A shorter span applies to the file at once, and Off removes it.
    func setRetention(_ retention: DictationHistoryRetention) {
        guard retention != settings.retention else { return }
        settings.retention = retention
        let now = Date()
        write {
            DictationHistoryFile.trim(retention: retention, now: now)
            DictationRecordingFolder.trim(now: now, historyCutoff: retention.cutoff(now: now))
        }
        applyEnabled()
        if let builtIndex, builtIndex.phase != .idle { builtIndex.reload(loader()) }
    }

    /// Only what comes next; replies already kept stay until they age out or are deleted.
    func setKeepsVoiceReplies(_ keeps: Bool) {
        settings.keepsVoiceReplies = keeps
        applyEnabled()
    }

    /// Off removes every recording kept; failures are still listed, without Retry.
    func setKeepsFailedRecordings(_ keeps: Bool) {
        settings.keepsFailedRecordings = keeps
        guard !keeps else { return }
        cancelRetries()
        builtIndex?.forgetRecordings()
        write { DictationRecordingFolder.clear() }
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
                duration: Self.duration(of: samples)))
    }

    /// A transcription that failed, with its recording while that is kept; silence leaves nothing.
    func recordFailure(samples: [Float], error: any Error, target: InjectionTarget?) {
        let retention = settings.retention
        guard retention.keepsHistory, !DictationRetry.isCancellation(error) else { return }
        let cloud = voiceCloud.isOn
        let mode = cloud ? voiceCloud.activeMode : nil
        let ownEditor = target?.ownEditor != nil
        let app = target?.externalApp
        let entry = DictationHistoryEntry(
            date: Date(), kind: .dictation, text: "", mode: mode?.name, modeID: mode?.id,
            engine: cloud ? .cloud : .onDevice,
            model: cloud ? voiceCloud.route?.model : appSettings.dictationModel.title,
            appName: ownEditor ? Bundle.main.appDisplayName : app?.localizedName,
            bundleID: ownEditor ? Bundle.main.bundleIdentifier : app?.bundleIdentifier,
            duration: Self.duration(of: samples.count), failure: Self.reason(for: error))
        let keepsAudio = settings.keepsFailedRecordings
        write { () -> Bool? in
            guard let wav = VoiceAudio.prepared(samples) else { return nil }
            if keepsAudio {
                let recording = DictationKeptRecording(id: entry.id, date: entry.date, bytes: wav.count)
                DictationRecordingFolder.keep(
                    wav, as: recording, historyCutoff: retention.cutoff(now: entry.date))
            }
            DictationHistoryFile.append(entry, retention: retention)
            return keepsAudio
        } then: { [weak self] recorded in
            guard let recorded else { return }
            self?.builtIndex?.insert(entry, recorded: recorded)
        }
    }

    private static func duration(of samples: Int) -> TimeInterval {
        (Double(samples) / Double(DictationWire.sampleRate) * 10).rounded() / 10
    }

    /// One line; a model's "no speech" over audio that held some reads as the misread it is.
    private static func reason(for error: any Error) -> String {
        guard error as? VoiceAIFailure != .noSpeech else {
            return DictationRetryFailure.noSpeech.localizedDescription
        }
        return error.localizedDescription
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
        cancelRetries()
        builtIndex?.close()
    }

    /// Waits for the writes already queued, so a dictation that just finished is listed.
    private func loader() -> @Sendable () async -> DictationHistorySnapshot {
        let retention = settings.retention
        let keepsAudio = settings.keepsFailedRecordings
        let pending = lastWrite
        return {
            await pending?.value
            return await Self.load(retention: retention, keepsAudio: keepsAudio)
        }
    }

    /// The recordings folder is listed only when some entry failed.
    @concurrent
    private static func load(retention: DictationHistoryRetention, keepsAudio: Bool) async
        -> DictationHistorySnapshot
    {
        let now = Date()
        let entries = DictationHistoryFile.load(retention: retention, now: now)
        let failed = Set(entries.filter(\.isFailed).map(\.id))
        guard keepsAudio, !failed.isEmpty else { return DictationHistorySnapshot(entries: entries) }
        let kept = DictationRecordingFolder.kept(now: now, historyCutoff: retention.cutoff(now: now))
        return DictationHistorySnapshot(entries: entries, recordings: kept.intersection(failed))
    }

    // MARK: - Retry

    /// What a dictation would use now: the consented cloud route, else the model on this Mac.
    var currentRetryEngine: RetryEngine? {
        voice.cloudDictation ? voiceCloud.route.map(RetryEngine.cloud) : .onDevice(appSettings.dictationModel)
    }

    /// Retry with…: every route the voice settings offer, then each model installed on this Mac.
    var retryEngines: [(title: String, engine: RetryEngine)] {
        let onThisMac = String(
            localized: "On this Mac", comment: "Where a dictation was transcribed, beside Cloud")
        let local = DictationModel.allCases.filter(core.dictationModels.isInstalled).map {
            (onThisMac + " · " + $0.title, RetryEngine.onDevice($0))
        }
        return voiceCloud.retryRoutes.map { ($0.title, RetryEngine.cloud($0.selection)) } + local
    }

    func canRetry(_ entry: DictationHistoryEntry) -> Bool {
        guard entry.isFailed, let builtIndex else { return false }
        return builtIndex.recordings.contains(entry.id) && !builtIndex.retries.isRetrying(entry.id)
    }

    func retry(_ entry: DictationHistoryEntry) {
        retry(entry, on: currentRetryEngine)
    }

    /// The kept recording transcribed again into the entry's text; nothing is typed anywhere.
    func retry(_ entry: DictationHistoryEntry, on engine: RetryEngine?) {
        guard canRetry(entry), let index = builtIndex, let attempt = index.retries.begin(entry.id)
        else { return }
        let pending = lastWrite
        retries[entry.id] = Task { [weak self] in
            let updated = await self?.retried(entry, on: engine, after: pending)
            guard let self, let index = builtIndex, index.retries.end(entry.id, attempt: attempt)
            else { return }
            retries[entry.id] = nil
            guard let updated else { return }
            index.update(updated)
            let transcribed = !updated.isFailed
            write {
                DictationHistoryFile.update(updated)
                if transcribed { DictationRecordingFolder.delete([updated.id]) }
            }
        }
    }

    private func retried(
        _ entry: DictationHistoryEntry, on engine: RetryEngine?, after pending: Task<Void, Never>?
    ) async -> DictationHistoryEntry? {
        if case .cloud(let selection) = engine {
            guard await voiceCloud.confirmRetry(on: selection), !Task.isCancelled else { return nil }
        }
        let mode = retryMode(for: entry)
        let attempt =
            switch engine {
            case .onDevice(let model): DictationRetryAttempt(engine: .onDevice, model: model.title)
            case .cloud, nil:
                DictationRetryAttempt(
                    engine: .cloud, model: cloudModel(of: engine), mode: mode?.name, modeID: mode?.id)
            }
        let samples = await Self.samples(for: entry.id, after: pending)
        return await DictationRetry.run(
            entry, samples: samples, attempt: attempt,
            transcribe: { [self] in
                try await transcribe($0, on: engine, mode: mode, appName: entry.appName)
            },
            describe: Self.reason(for:))
    }

    private func cloudModel(of engine: RetryEngine?) -> String? {
        guard case .cloud(let selection) = engine else { return nil }
        return selection.model
    }

    /// The cloud's own failure keeps its mode; one on this Mac takes the app's, as dictating would.
    private func retryMode(for entry: DictationHistoryEntry) -> VoiceMode? {
        entry.engine == .cloud ? voice.modes.mode(id: entry.modeID) : voice.modes.mode(for: entry.bundleID)
    }

    private func transcribe(
        _ samples: [Float], on engine: RetryEngine?, mode: VoiceMode?, appName: String?
    ) async throws -> DictationRetryTranscript {
        switch engine {
        case nil:
            throw VoiceAIFailure.noDictationModel
        case .cloud(let selection):
            let heard = try await voiceCloud.retranscribe(
                samples, on: selection, mode: mode, appName: appName)
            return DictationRetryTranscript(
                text: heard.text, transcript: heard.transcript, mode: heard.mode, engine: .cloud,
                model: heard.model)
        case .onDevice(let model):
            let text = try await core.dictationModels.transcribe(
                samples, model: model, language: appSettings.dictationLanguage)
            return DictationRetryTranscript(text: text, engine: .onDevice, model: model.title)
        }
    }

    @concurrent
    private static func samples(for id: UUID, after pending: Task<Void, Never>?) async -> [Float]? {
        await pending?.value
        return DictationRecordingFolder.samples(for: id, sampleRate: VoiceAudio.sampleRate)
    }

    private func cancelRetries() {
        retries.values.forEach { $0.cancel() }
        retries = [:]
        builtIndex?.retries.cancelAll()
    }

    // MARK: - Actions

    /// Typed where the caret was when the palette opened, as a snippet is, with the clipboard kept.
    func paste(_ entry: DictationHistoryEntry) {
        guard !entry.isFailed else { return }
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
        guard !entry.isFailed else { return }
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
        let entry = rows[min(max(palette.selection, 0), rows.count - 1)]
        guard !entry.isFailed else { return false }
        copy(entry)
        return true
    }

    func delete(_ entry: DictationHistoryEntry) {
        retries.removeValue(forKey: entry.id)?.cancel()
        builtIndex?.remove([entry.id])
        write {
            DictationHistoryFile.delete([entry.id])
            DictationRecordingFolder.delete([entry.id])
        }
    }

    /// ⌃⇧X, the ⌘K row and Settings' Clear… all land here, so none skips the question.
    func clearHistory() async {
        guard
            await core.confirm(
                title: String(localized: "Clear dictation history?"),
                message: String(localized: "Every transcript in it is removed. This can't be undone."),
                symbol: CommandID.dictationHistory.sfSymbol, confirmTitle: String(localized: "Clear History"))
        else { return }
        cancelRetries()
        builtIndex?.removeAll()
        write {
            DictationHistoryFile.clear()
            DictationRecordingFolder.clear()
        }
    }

    private func write(_ work: @escaping @Sendable () -> Void) {
        let previous = lastWrite
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
            work()
        }
    }

    private func write<Result: Sendable>(
        _ work: @escaping @Sendable () -> Result, then: @escaping @MainActor @Sendable (Result) -> Void
    ) {
        let previous = lastWrite
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
            let result = work()
            await then(result)
        }
    }
}
