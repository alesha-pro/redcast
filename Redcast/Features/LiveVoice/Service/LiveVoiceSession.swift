import Foundation
import Synchronization

/// One live conversation: the socket, the audio, the screen and the tools, tied to one wire.
@MainActor
final class LiveVoiceSession {
    /// What a surface shows; nothing here is needed to keep the conversation going.
    enum Update: Sendable {
        case ready
        case listening(LiveVoiceAudio.Echo)
        case userSpeaking
        case thinking
        case speaking
        case reconnecting
        case heard(String)
        case said(String)
        case replyEnded(LiveVoiceUsage?)
        /// Seconds from the end of the user's speech to the reply's first sound.
        case latency(Double)
        case calling(AIToolCall)
        case tool(AIToolCall, AIToolResult)
        case failed(String)
        case closed
    }

    private var wire: any LiveVoiceWire
    private let toolbox: LiveVoiceToolbox
    private let setup: LiveVoiceSetup
    private let screen: LiveVoiceScreenTools?
    private let sendsScreenEachTurn: Bool
    private let audio: LiveVoiceAudio?
    private let echo: LiveVoiceAudio.Echo
    private let microphoneUID: String?
    private let maxConnectionLifetime: Duration?
    private let reconnectDelays: [Duration]
    private let onUpdate: @MainActor (Update) -> Void

    private var connection: LiveVoiceConnection?
    private let sendBox = ActiveConnectionBox()
    private var reader: Task<Void, Never>?
    private var lifetimeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var runningTools: [String: Task<Void, Never>] = [:]
    private var waiterTasks: [Task<Void, Never>] = []
    private var replyIsOpen = false
    private var owesReply = false
    private var speechEnded: ContinuousClock.Instant?
    private var saidScreenIsHidden = false
    private var isReady = false
    private var isAudioStarted = false
    private var activeEcho: LiveVoiceAudio.Echo = .open
    private var isStopped = false
    private var resumptionHandle: String?
    private var reconnectPending = false
    private var reconnectAttempts = 0
    private var isReconnecting = false
    private var ignoredAudioItem: String?
    private var transcript = LiveVoiceTranscript()

    static let hiddenScreen =
        "The screen could not be captured. Allow Screen Recording for this app in System Settings."
    private static let hiddenScreenNote =
        "No screenshot could be taken: this app is not allowed to record the screen. You cannot see the "
        + "screen or point at it until the user allows Screen Recording in System Settings. Never guess what is there."

    init(
        wire: any LiveVoiceWire, setup: LiveVoiceSetup, toolbox: LiveVoiceToolbox,
        screen: LiveVoiceScreenTools?, sendsScreenEachTurn: Bool, audio: LiveVoiceAudio?,
        echo: LiveVoiceAudio.Echo = .cancelled, microphoneUID: String? = nil,
        maxConnectionLifetime: Duration? = nil,
        reconnectDelays: [Duration] = [.milliseconds(500), .milliseconds(1_500), .seconds(3)],
        onUpdate: @escaping @MainActor (Update) -> Void
    ) {
        self.wire = wire
        self.setup = setup
        self.toolbox = toolbox
        self.screen = screen
        self.sendsScreenEachTurn = sendsScreenEachTurn
        self.audio = audio
        self.echo = echo
        self.microphoneUID = microphoneUID
        self.maxConnectionLifetime = maxConnectionLifetime
        self.reconnectDelays = reconnectDelays
        self.onUpdate = onUpdate
    }

    func start() {
        guard connection == nil, !isStopped else { return }
        openConnection(resuming: false)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        finish(saying: nil)
    }

    /// Manually cuts the assistant's speech and cancels the active reply from the UI.
    func interrupt() {
        guard !isStopped else { return }
        cutPlayback(tellsProvider: true, cancelsReply: true)
        replyIsOpen = false
        owesReply = false
        if isAudioStarted { onUpdate(.listening(activeEcho)) }
    }

    func setMuted(_ muted: Bool) {
        audio?.isMuted = muted
    }

    /// Captures and sends the screen now, used on Gemini where turns do not emit speech-start.
    func lookNow() async {
        await sendScreen()
    }

    /// A typed question gets the turn a spoken one would, screenshot included.
    func ask(_ text: String, withScreen: Bool) async {
        if withScreen { await sendScreen() }
        guard let connection, !isStopped else { return }
        transcript.noteUserText(text)
        connection.send(wire.typed(text))
        askForReply()
    }

    /// Speech from somewhere other than the microphone: PCM16 mono at the wire's input rate.
    func hear(_ pcm: Data) {
        connection?.send(wire.audio(pcm))
    }

    private func openConnection(resuming: Bool) {
        let connection = LiveVoiceConnection(wire.request)
        self.connection = connection
        sendBox.set(nil)
        isReady = false
        replyIsOpen = false
        owesReply = false
        ignoredAudioItem = nil
        var openingSetup = setup
        if resuming { openingSetup.resumptionHandle = resumptionHandle }
        connection.send(wire.opening(openingSetup))
        let isResumeAttempt = resuming
        reader = Task { [weak self] in
            do {
                for try await message in connection.messages() {
                    guard let self, self.connection === connection else { return }
                    for event in self.wire.events(from: message) {
                        await self.handle(event, isResumeAttempt: isResumeAttempt)
                    }
                }
                self?.handleDisconnect(connection, failure: nil)
            } catch {
                self?.handleDisconnect(connection, failure: error.localizedDescription)
            }
        }
    }

    private func armLifetimeTimer() {
        lifetimeTask?.cancel()
        guard let maxConnectionLifetime else { return }
        lifetimeTask = Task { [weak self] in
            try? await Task.sleep(for: maxConnectionLifetime)
            guard !Task.isCancelled, let self, !self.isStopped else { return }
            self.requestGracefulReconnect()
        }
    }

    private func requestGracefulReconnect() {
        reconnectPending = true
        guard !replyIsOpen, runningTools.isEmpty else { return }
        reconnectPending = false
        scheduleReconnect(immediate: true)
    }

    private func handleDisconnect(_ ended: LiveVoiceConnection, failure: String?) {
        guard connection === ended else { return }
        connection = nil
        sendBox.set(nil)
        reader?.cancel()
        reader = nil
        lifetimeTask?.cancel()
        lifetimeTask = nil
        ended.close()
        cancelRunningTools()
        replyIsOpen = false
        owesReply = false
        guard !isStopped else { return }
        // Only reconnect if the session had already succeeded once or is mid-reconnect.
        guard isReady || isReconnecting, reconnectAttempts < reconnectDelays.count else {
            finish(saying: failure)
            return
        }
        scheduleReconnect(immediate: false)
    }

    private func scheduleReconnect(immediate: Bool) {
        guard !isStopped else { return }
        reconnectTask?.cancel()
        let old = connection
        connection = nil
        sendBox.set(nil)
        reader?.cancel()
        reader = nil
        lifetimeTask?.cancel()
        lifetimeTask = nil
        old?.close()
        cancelRunningTools()
        replyIsOpen = false
        owesReply = false
        isReconnecting = true
        onUpdate(.reconnecting)
        let delay: Duration =
            immediate ? .zero : reconnectDelays[min(reconnectAttempts, reconnectDelays.count - 1)]
        if !immediate { reconnectAttempts += 1 }
        reconnectTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, !self.isStopped else { return }
            self.reconnectTask = nil
            self.openConnection(resuming: true)
        }
    }

    private func announce(_ note: String) {
        guard let connection, !isStopped else { return }
        connection.send(wire.note(note))
        askForReply()
    }

    private func finish(saying failure: String?) {
        isStopped = true
        let active = connection
        connection = nil
        sendBox.set(nil)
        reader?.cancel()
        reader = nil
        lifetimeTask?.cancel()
        lifetimeTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelRunningTools()
        for waiter in waiterTasks { waiter.cancel() }
        waiterTasks = []
        screen?.cancel()
        audio?.stop()
        active?.close()
        if let failure { onUpdate(.failed(failure)) }
        onUpdate(.closed)
    }

    private func cancelRunningTools() {
        for task in runningTools.values { task.cancel() }
        runningTools = [:]
    }

    private func handle(_ event: LiveVoiceEvent, isResumeAttempt: Bool) async {
        switch event {
        case .ready:
            isReady = true
            let wasReconnecting = isReconnecting
            isReconnecting = false
            reconnectAttempts = 0
            sendBox.set(connection)
            armLifetimeTimer()
            if wasReconnecting, resumptionHandle == nil, let recap = transcript.recap() {
                connection?.send(wire.note(recap))
            }
            onUpdate(.ready)
            if !isAudioStarted {
                await startAudio()
            } else {
                onUpdate(.listening(activeEcho))
            }
        case .userStartedSpeaking:
            cutPlayback(tellsProvider: true, cancelsReply: false)
            onUpdate(.userSpeaking)
            if sendsScreenEachTurn { Task { await sendScreen() } }
        case .userStoppedSpeaking:
            speechEnded = .now
            onUpdate(.thinking)
        case .replyStarted:
            replyIsOpen = true
            ignoredAudioItem = nil
            onUpdate(.thinking)
        case .heard(let text):
            transcript.noteUserText(text)
            onUpdate(.heard(text))
        case .audio(let pcm, let item):
            if let ignored = ignoredAudioItem, !item.isEmpty, ignored == item { return }
            replyIsOpen = true
            if let speechEnded {
                onUpdate(.latency(Self.seconds(ContinuousClock.now - speechEnded)))
                self.speechEnded = nil
            }
            onUpdate(.speaking)
            play(pcm, of: item)
        case .said(let text):
            replyIsOpen = true
            transcript.noteAssistantText(text)
            onUpdate(.said(text))
        case .toolCall(let call):
            replyIsOpen = true
            run(call)
        case .toolCallsCancelled(let ids):
            for id in ids {
                runningTools.removeValue(forKey: id)?.cancel()
            }
        case .interrupted:
            cutPlayback(tellsProvider: false, cancelsReply: false)
            if isAudioStarted { onUpdate(.listening(activeEcho)) }
        case .resumptionHandle(let handle):
            resumptionHandle = handle
        case .sessionExpiring:
            requestGracefulReconnect()
        case .replyEnded(let usage):
            replyIsOpen = false
            ignoredAudioItem = nil
            transcript.finishReply()
            onUpdate(.replyEnded(usage))
            if reconnectPending, runningTools.isEmpty {
                reconnectPending = false
                scheduleReconnect(immediate: true)
            } else if owesReply {
                askForReply()
            } else if isAudioStarted, audio?.isSpeaking != true {
                onUpdate(.listening(activeEcho))
            }
        case .failed(let message):
            // A provider that refuses the opening keeps the socket open and never says ready.
            if !isReady {
                if isResumeAttempt, reconnectAttempts < reconnectDelays.count {
                    // A stale resumption handle fails setup; retry once cleanly without it.
                    resumptionHandle = nil
                    scheduleReconnect(immediate: false)
                } else {
                    finish(saying: message)
                }
            } else {
                onUpdate(.failed(message))
            }
        }
    }

    private func startAudio() async {
        guard let audio, let connection else { return }
        let encoder = wire
        let sendBox = sendBox
        audio.onSpeakingChanged = { [weak self] speaking in
            guard let self, !self.isStopped else { return }
            if speaking {
                self.onUpdate(.speaking)
            } else if !self.replyIsOpen, self.runningTools.isEmpty, !self.isReconnecting {
                self.onUpdate(.listening(self.activeEcho))
            }
        }
        do {
            let inEffect = try await audio.start(
                inputRate: wire.inputRate, outputRate: wire.outputRate, echo: echo,
                microphoneUID: microphoneUID
            ) { pcm in
                sendBox.send(encoder.audio(pcm))
            }
            guard self.connection === connection, !isStopped else {
                audio.stop()
                return
            }
            isAudioStarted = true
            activeEcho = inEffect
            onUpdate(.listening(inEffect))
        } catch {
            let message =
                (error as? any LocalizedError)?.errorDescription
                ?? String(localized: "Couldn't open the microphone or audio output.")
            finish(saying: message)
        }
    }

    private func play(_ pcm: Data, of item: String) {
        do {
            try audio?.play(pcm, of: item)
        } catch {
            let message =
                (error as? any LocalizedError)?.errorDescription
                ?? String(localized: "Couldn't play the voice reply.")
            onUpdate(.failed(message))
        }
    }

    private func cutPlayback(tellsProvider: Bool, cancelsReply: Bool) {
        let cut = audio?.interrupt()
        if let cut, !cut.item.isEmpty { ignoredAudioItem = cut.item }
        if cancelsReply, replyIsOpen { connection?.send(wire.cancelReply()) }
        guard let cut, tellsProvider else { return }
        connection?.send(wire.interruption(played: cut.milliseconds, of: cut.item))
    }

    private func sendScreen() async {
        guard let screen, let connection else { return }
        let image = await screen.look()
        guard self.connection === connection, !isStopped else { return }
        guard let image else {
            guard !saidScreenIsHidden else { return }
            saidScreenIsHidden = true
            connection.send(wire.note(Self.hiddenScreenNote))
            onUpdate(.failed(Self.hiddenScreen))
            return
        }
        saidScreenIsHidden = false
        connection.send(wire.image(image.jpeg, caption: LiveVoiceScreenTools.caption(image.frame)))
    }

    private func run(_ call: AIToolCall) {
        guard let connection else { return }
        onUpdate(.calling(call))
        onUpdate(.thinking)
        let context = LiveVoiceToolContext(
            announce: { [weak self] note in self?.announce(note) },
            track: { [weak self] task in self?.waiterTasks.append(task) })
        let task = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.toolbox.run(call, in: context)
            guard !Task.isCancelled, self.connection === connection, !self.isStopped else { return }
            self.runningTools.removeValue(forKey: call.id)
            connection.send(
                self.wire.toolResult(
                    outcome.result, for: call, image: outcome.image?.jpeg,
                    caption: outcome.image.map { LiveVoiceScreenTools.caption($0.frame) } ?? ""))
            self.onUpdate(.tool(call, outcome.result))
            if self.reconnectPending, !self.replyIsOpen, self.runningTools.isEmpty {
                self.reconnectPending = false
                self.scheduleReconnect(immediate: true)
            } else {
                self.askForReply()
            }
        }
        runningTools[call.id] = task
    }

    /// A provider refuses a second reply while one is open or a call is still out.
    private func askForReply() {
        guard !replyIsOpen, runningTools.isEmpty else {
            owesReply = true
            return
        }
        owesReply = false
        connection?.send(wire.reply())
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// Thread-safe handle so the audio thread always writes to the current socket across reconnects.
private final class ActiveConnectionBox: Sendable {
    private let current = Mutex<LiveVoiceConnection?>(nil)

    func set(_ connection: LiveVoiceConnection?) {
        current.withLock { $0 = connection }
    }

    func send(_ text: String) {
        let target = current.withLock { $0 }
        target?.send(text)
    }
}
