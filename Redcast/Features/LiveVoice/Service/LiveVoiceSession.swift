import Foundation

/// One live conversation: the socket, the audio, the screen and the tools, tied to one wire.
@MainActor
final class LiveVoiceSession {
    /// What a surface shows; nothing here is needed to keep the conversation going.
    enum Update: Sendable {
        case ready
        case listening(LiveVoiceAudio.Echo)
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
    private let onUpdate: @MainActor (Update) -> Void

    private var connection: LiveVoiceConnection?
    private var reader: Task<Void, Never>?
    private var replyIsOpen = false
    private var runningCalls = 0
    private var owesReply = false
    private var speechEnded: ContinuousClock.Instant?
    private var saidScreenIsHidden = false
    private var isReady = false

    static let hiddenScreen = "The screen could not be captured. Allow Screen Recording for this app in System Settings."
    private static let hiddenScreenNote =
        "No screenshot could be taken: this app is not allowed to record the screen. You cannot see the "
        + "screen or point at it until the user allows Screen Recording in System Settings. Never guess what is there."

    init(
        wire: any LiveVoiceWire, setup: LiveVoiceSetup, toolbox: LiveVoiceToolbox,
        screen: LiveVoiceScreenTools?, sendsScreenEachTurn: Bool, audio: LiveVoiceAudio?,
        echo: LiveVoiceAudio.Echo = .cancelled, onUpdate: @escaping @MainActor (Update) -> Void
    ) {
        self.wire = wire
        self.setup = setup
        self.toolbox = toolbox
        self.screen = screen
        self.sendsScreenEachTurn = sendsScreenEachTurn
        self.audio = audio
        self.echo = echo
        self.onUpdate = onUpdate
    }

    func start() {
        guard connection == nil else { return }
        let connection = LiveVoiceConnection(wire.request)
        self.connection = connection
        connection.send(wire.opening(setup))
        reader = Task { [weak self] in
            do {
                for try await message in connection.messages() {
                    guard let self, self.connection === connection else { return }
                    for event in self.wire.events(from: message) { await self.handle(event) }
                }
                self?.end(connection, saying: nil)
            } catch {
                self?.end(connection, saying: error.localizedDescription)
            }
        }
    }

    func stop() {
        guard let connection else { return }
        end(connection, saying: nil)
    }

    /// A typed question gets the turn a spoken one would, screenshot included.
    func ask(_ text: String, withScreen: Bool) async {
        if withScreen { await sendScreen() }
        guard let connection else { return }
        connection.send(wire.typed(text))
        askForReply()
    }

    /// Speech from somewhere other than the microphone: PCM16 mono at the wire's input rate.
    func hear(_ pcm: Data) {
        connection?.send(wire.audio(pcm))
    }

    private func announce(_ note: String) {
        guard let connection else { return }
        connection.send(wire.note(note))
        askForReply()
    }

    private func end(_ ended: LiveVoiceConnection, saying failure: String?) {
        guard connection === ended else { return }
        connection = nil
        reader?.cancel()
        reader = nil
        audio?.stop()
        ended.close()
        if let failure { onUpdate(.failed(failure)) }
        onUpdate(.closed)
    }

    private func handle(_ event: LiveVoiceEvent) async {
        switch event {
        case .ready:
            isReady = true
            onUpdate(.ready)
            await startAudio()
        case .userStartedSpeaking:
            cutPlayback(tellsProvider: true)
            if sendsScreenEachTurn { Task { await sendScreen() } }
        case .userStoppedSpeaking:
            speechEnded = .now
        case .replyStarted:
            replyIsOpen = true
        case .heard(let text):
            onUpdate(.heard(text))
        case .audio(let pcm, let item):
            replyIsOpen = true
            if let speechEnded {
                onUpdate(.latency(Self.seconds(ContinuousClock.now - speechEnded)))
                self.speechEnded = nil
            }
            play(pcm, of: item)
        case .said(let text):
            replyIsOpen = true
            onUpdate(.said(text))
        case .toolCall(let call):
            replyIsOpen = true
            run(call)
        case .interrupted:
            cutPlayback(tellsProvider: false)
        case .replyEnded(let usage):
            replyIsOpen = false
            onUpdate(.replyEnded(usage))
            if owesReply { askForReply() }
        case .failed(let message):
            // A provider that refuses the opening keeps the socket open and never says ready.
            if !isReady, let connection { end(connection, saying: message) } else { onUpdate(.failed(message)) }
        }
    }

    private func startAudio() async {
        guard let audio, let connection else { return }
        let encoder = wire
        do {
            let inEffect = try await audio.start(
                inputRate: wire.inputRate, outputRate: wire.outputRate, echo: echo
            ) { pcm in
                connection.send(encoder.audio(pcm))
            }
            guard self.connection === connection else { return }
            onUpdate(.listening(inEffect))
        } catch {
            end(connection, saying: "The microphone could not be opened: \(error)")
        }
    }

    private func play(_ pcm: Data, of item: String) {
        do {
            try audio?.play(pcm, of: item)
        } catch {
            onUpdate(.failed("The reply could not be played: \(error)"))
        }
    }

    private func cutPlayback(tellsProvider: Bool) {
        guard let cut = audio?.interrupt(), tellsProvider else { return }
        connection?.send(wire.interruption(played: cut.milliseconds, of: cut.item))
    }

    private func sendScreen() async {
        guard let screen, let connection else { return }
        let image = await screen.look()
        guard self.connection === connection else { return }
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
        runningCalls += 1
        onUpdate(.calling(call))
        let context = LiveVoiceToolContext { [weak self] note in self?.announce(note) }
        Task {
            let outcome = await toolbox.run(call, in: context)
            guard self.connection === connection else { return }
            runningCalls -= 1
            connection.send(
                wire.toolResult(
                    outcome.result, for: call, image: outcome.image?.jpeg,
                    caption: outcome.image.map { LiveVoiceScreenTools.caption($0.frame) } ?? ""))
            onUpdate(.tool(call, outcome.result))
            askForReply()
        }
    }

    /// A provider refuses a second reply while one is open or a call is still out.
    private func askForReply() {
        guard !replyIsOpen, runningCalls == 0 else {
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
