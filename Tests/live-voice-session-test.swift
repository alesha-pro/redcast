import Foundation
import Network

/// OpenAI's dialect pointed at a server on this Mac, so a whole session runs with no network.
struct LoopbackWire: LiveVoiceWire {
    var inner = OpenAIRealtimeWire(key: "test")
    let port: UInt16

    var request: URLRequest { URLRequest(url: URL(string: "ws://127.0.0.1:\(port)")!) }
    var inputRate: Int { inner.inputRate }
    var outputRate: Int { inner.outputRate }
    func opening(_ setup: LiveVoiceSetup) -> [String] { inner.opening(setup) }
    func audio(_ pcm: Data) -> String { inner.audio(pcm) }
    func image(_ jpeg: Data, caption: String) -> [String] { inner.image(jpeg, caption: caption) }
    func typed(_ text: String) -> [String] { inner.typed(text) }
    func note(_ text: String) -> [String] { inner.note(text) }
    func toolResult(_ result: AIToolResult, for call: AIToolCall, image: Data?, caption: String) -> [String] {
        inner.toolResult(result, for: call, image: image, caption: caption)
    }
    func reply() -> [String] { inner.reply() }
    func cancelReply() -> [String] { inner.cancelReply() }
    func interruption(played milliseconds: Int, of item: String) -> [String] {
        inner.interruption(played: milliseconds, of: item)
    }
    mutating func events(from message: Data) -> [LiveVoiceEvent] { inner.events(from: message) }
}

/// Gemini's dialect pointed at a server on this Mac, to test session resumption and goAway.
struct LoopbackGeminiWire: LiveVoiceWire {
    var inner = GeminiLiveWire(key: "test")
    let port: UInt16

    var request: URLRequest { URLRequest(url: URL(string: "ws://127.0.0.1:\(port)")!) }
    var inputRate: Int { inner.inputRate }
    var outputRate: Int { inner.outputRate }
    func opening(_ setup: LiveVoiceSetup) -> [String] { inner.opening(setup) }
    func audio(_ pcm: Data) -> String { inner.audio(pcm) }
    func image(_ jpeg: Data, caption: String) -> [String] { inner.image(jpeg, caption: caption) }
    func typed(_ text: String) -> [String] { inner.typed(text) }
    func note(_ text: String) -> [String] { inner.note(text) }
    func toolResult(_ result: AIToolResult, for call: AIToolCall, image: Data?, caption: String) -> [String] {
        inner.toolResult(result, for: call, image: image, caption: caption)
    }
    func reply() -> [String] { inner.reply() }
    func cancelReply() -> [String] { inner.cancelReply() }
    func interruption(played milliseconds: Int, of item: String) -> [String] {
        inner.interruption(played: milliseconds, of: item)
    }
    mutating func events(from message: Data) -> [LiveVoiceEvent] { inner.events(from: message) }
}

/// A scripted stand-in for the provider: it records what arrives and answers through `respond`.
final class ScriptedServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "live-voice-session-test")
    private var connection: NWConnection?
    private(set) var received: [String] = []
    private(set) var rawMessages: [[String: JSONValue]] = []
    private(set) var connectionCount = 0
    private let respond: @Sendable (ScriptedServer, [String: JSONValue]) -> Void

    init(respond: @escaping @Sendable (ScriptedServer, [String: JSONValue]) -> Void) throws {
        let parameters = NWParameters.tcp
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        self.respond = respond
    }

    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            listener.newConnectionHandler = { [self] connection in
                self.connection = connection
                self.connectionCount += 1
                connection.start(queue: queue)
                receive(on: connection)
            }
            listener.stateUpdateHandler = { [listener] state in
                guard case .ready = state else { return }
                continuation.resume(returning: listener.port?.rawValue ?? 0)
            }
            listener.start(queue: queue)
        }
    }

    /// What arrived so far, as each message's kind: its type, or its item's type.
    var kinds: [String] { queue.sync { received } }
    var connections: Int { queue.sync { connectionCount } }
    var messages: [[String: JSONValue]] { queue.sync { rawMessages } }

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection?.send(content: data, contentContext: context, completion: .idempotent)
    }

    func dropClient() {
        queue.async { [self] in
            connection?.cancel()
            connection = nil
        }
    }

    func stop() {
        connection?.cancel()
        listener.cancel()
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [self] data, _, _, error in
            guard error == nil, let data, let message = JSONValue(data: data)?.objectValue else { return }
            rawMessages.append(message)
            let type = message["type"]?.stringValue ?? message.keys.sorted().first ?? "?"
            let item = message["item"]?.objectValue
            let part = item?["content"]?.arrayValue?.last?.objectValue?["type"]?.stringValue
            received.append([type, item?["type"]?.stringValue, part].compactMap(\.self).joined(separator: ":"))
            respond(self, message)
            receive(on: connection)
        }
    }
}

@main
@MainActor
struct LiveVoiceSessionTests {
    static func name(_ update: LiveVoiceSession.Update) -> String {
        switch update {
        case .ready: "ready"
        case .listening: "listening"
        case .userSpeaking: "userSpeaking"
        case .thinking: "thinking"
        case .speaking: "speaking"
        case .reconnecting: "reconnecting"
        case .heard(let text): "heard \(text)"
        case .said(let text): "said \(text)"
        case .replyEnded(let usage): "ended \(usage?.output ?? -1)"
        case .latency: "latency"
        case .calling(let call): "calling \(call.name)"
        case .tool(let call, let result): "tool \(call.name) \(result.isError ? "error" : "ok")"
        case .failed(let message): "failed \(message)"
        case .closed: "closed"
        }
    }

    /// One session against `server`, asking `question` once ready; its updates until `last` or ten seconds.
    static func updates(
        of server: ScriptedServer, capture: @escaping @MainActor () async -> LiveVoiceImage?, question: String?,
        until last: String
    ) async -> (updates: [String], session: LiveVoiceSession) {
        let port = await server.start()
        let screen = LiveVoiceScreenTools(offersLook: false, capture: capture, locate: nil, point: { _, _ in })
        let toolbox = LiveVoiceToolbox(sources: [screen])
        var updates: [String] = []
        let (stream, signal) = AsyncStream<String>.makeStream()
        let session = LiveVoiceSession(
            wire: LoopbackWire(port: port),
            setup: LiveVoiceSetup(instructions: "Test.", tools: toolbox.tools, voice: nil), toolbox: toolbox,
            screen: screen, sendsScreenEachTurn: false, audio: nil,
            reconnectDelays: [.milliseconds(20), .milliseconds(20)]
        ) { update in
            let label = name(update)
            updates.append(label)
            signal.yield(label)
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            signal.finish()
        }
        session.start()
        for await update in stream {
            if update == "ready", let question { await session.ask(question, withScreen: true) }
            if update == last { break }
        }
        watchdog.cancel()
        return (updates, session)
    }

    /// A capture that fails is told to the model once, before the question, and to the surface.
    static func hiddenScreen() async {
        guard
            let server = try? ScriptedServer(respond: { server, message in
                switch message["type"]?.stringValue {
                case "session.update":
                    server.send(["type": "session.updated"])
                case "response.create":
                    server.send(["type": "response.created"])
                    server.send(["type": "response.done", "response": ["status": "completed"]])
                default:
                    break
                }
            })
        else { return expect(false, "the scripted server starts") }
        let run = await updates(of: server, capture: { nil }, question: "What is this?", until: "ended -1")
        expect(
            run.updates == ["ready", "failed \(LiveVoiceSession.hiddenScreen)", "thinking", "ended -1"],
            "a screen that cannot be captured is reported once: \(run.updates)")
        expect(
            server.kinds == [
                "session.update", "conversation.item.create:message:input_text",
                "conversation.item.create:message:input_text", "response.create",
            ], "the model is told before the question, with no picture: \(server.kinds)")
        run.session.stop()
        server.stop()
    }

    /// A provider that refuses the opening and keeps the socket open still ends the session.
    static func refusedOpening() async {
        guard
            let server = try? ScriptedServer(respond: { server, message in
                guard message["type"]?.stringValue == "session.update" else { return }
                server.send(["type": "error", "error": ["message": "Unsupported option for this model."]])
            })
        else { return expect(false, "the scripted server starts") }
        let run = await updates(of: server, capture: { nil }, question: nil, until: "closed")
        expect(
            run.updates == ["failed Unsupported option for this model.", "closed"],
            "a refused opening closes the session: \(run.updates)")
        server.stop()
    }

    /// Gemini goAway triggers a graceful reconnect carrying the latest resumption handle.
    static func geminiResumptionReconnect() async {
        guard
            let server = try? ScriptedServer(respond: { server, message in
                guard message["setup"] != nil else { return }
                server.send(["setupComplete": [String: Any]()])
                if server.connectionCount == 1 {
                    server.send([
                        "sessionResumptionUpdate": ["newHandle": "resume_abc", "resumable": true]
                    ])
                    server.send(["goAway": ["timeLeft": "30s"]])
                }
            })
        else { return expect(false, "the scripted server starts") }
        let port = await server.start()
        var updates: [String] = []
        let (stream, signal) = AsyncStream<String>.makeStream()
        var readyCount = 0
        let session = LiveVoiceSession(
            wire: LoopbackGeminiWire(port: port),
            setup: LiveVoiceSetup(instructions: "Test.", tools: [], voice: nil),
            toolbox: LiveVoiceToolbox(sources: []), screen: nil, sendsScreenEachTurn: false, audio: nil,
            reconnectDelays: [.milliseconds(20)]
        ) { update in
            let label = name(update)
            updates.append(label)
            signal.yield(label)
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            signal.finish()
        }
        session.start()
        for await update in stream where update == "ready" {
            readyCount += 1
            if readyCount == 2 { break }
        }
        watchdog.cancel()
        expect(server.connections == 2, "goAway opened a second WebSocket connection: \(server.connections)")
        expect(updates == ["ready", "reconnecting", "ready"], "session reported reconnect cleanly: \(updates)")
        let secondSetup = server.messages.last?["setup"]?.objectValue
        let sentHandle = secondSetup?["sessionResumption"]?.objectValue?["handle"]?.stringValue
        expect(
            sentHandle == "resume_abc",
            "reconnected Gemini setup carries resumption handle: \(String(describing: sentHandle))")
        session.stop()
        server.stop()
    }

    /// OpenAI hitting its lifetime limit reconnects proactively and sends a transcript recap note.
    static func openAILifetimeReconnect() async {
        guard
            let server = try? ScriptedServer(respond: { server, message in
                switch message["type"]?.stringValue {
                case "session.update":
                    server.send(["type": "session.updated"])
                case "response.create":
                    server.send(["type": "response.created"])
                    server.send(["type": "response.output_audio_transcript.delta", "delta": "Hello!"])
                    server.send(["type": "response.done", "response": ["status": "completed"]])
                default:
                    break
                }
            })
        else { return expect(false, "the scripted server starts") }
        let port = await server.start()
        var updates: [String] = []
        let (stream, signal) = AsyncStream<String>.makeStream()
        var readyCount = 0
        let session = LiveVoiceSession(
            wire: LoopbackWire(port: port),
            setup: LiveVoiceSetup(instructions: "Test.", tools: [], voice: nil),
            toolbox: LiveVoiceToolbox(sources: []), screen: nil, sendsScreenEachTurn: false, audio: nil,
            maxConnectionLifetime: .milliseconds(150),
            reconnectDelays: [.milliseconds(20)]
        ) { update in
            let label = name(update)
            updates.append(label)
            signal.yield(label)
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            signal.finish()
        }
        session.start()
        for await update in stream where update == "ready" {
            readyCount += 1
            if readyCount == 1 {
                await session.ask("Ping", withScreen: false)
            } else if readyCount == 2 {
                break
            }
        }
        watchdog.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        expect(server.connections == 2, "lifetime limit triggered proactive reconnect: \(server.connections)")
        expect(updates.contains("reconnecting"), "reconnecting update emitted")
        let sentSystemNote = server.messages.contains { msg in
            let item = msg["item"]?.objectValue
            let text = item?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
            return item?["role"]?.stringValue == "system" && text.contains("User: Ping") && text.contains("Assistant: Hello!")
        }
        expect(sentSystemNote, "reconnected OpenAI session received prior transcript recap")
        session.stop()
        server.stop()
    }

    /// Manual interrupt sends response.cancel while a reply is open.
    static func manualInterrupt() async {
        guard
            let server = try? ScriptedServer(respond: { server, message in
                switch message["type"]?.stringValue {
                case "session.update":
                    server.send(["type": "session.updated"])
                case "response.create":
                    server.send(["type": "response.created"])
                    server.send(["type": "response.output_audio_transcript.delta", "delta": "Long reply"])
                default:
                    break
                }
            })
        else { return expect(false, "the scripted server starts") }
        let port = await server.start()
        let (stream, signal) = AsyncStream<String>.makeStream()
        let session = LiveVoiceSession(
            wire: LoopbackWire(port: port),
            setup: LiveVoiceSetup(instructions: "Test.", tools: [], voice: nil),
            toolbox: LiveVoiceToolbox(sources: []), screen: nil, sendsScreenEachTurn: false, audio: nil
        ) { update in
            signal.yield(name(update))
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            signal.finish()
        }
        session.start()
        for await update in stream {
            if update == "ready" { await session.ask("Talk", withScreen: false) }
            if update == "said Long reply" {
                session.interrupt()
                break
            }
        }
        watchdog.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        expect(server.kinds.contains("response.cancel"), "manual interrupt sent response.cancel: \(server.kinds)")
        session.stop()
        server.stop()
    }

    /// An unexpected socket drop after ready reconnects automatically.
    static func socketDropReconnect() async {
        guard
            let server = try? ScriptedServer(respond: { server, message in
                guard message["type"]?.stringValue == "session.update" else { return }
                server.send(["type": "session.updated"])
                if server.connectionCount == 1 {
                    server.dropClient()
                }
            })
        else { return expect(false, "the scripted server starts") }
        let port = await server.start()
        var updates: [String] = []
        let (stream, signal) = AsyncStream<String>.makeStream()
        var readyCount = 0
        let session = LiveVoiceSession(
            wire: LoopbackWire(port: port),
            setup: LiveVoiceSetup(instructions: "Test.", tools: [], voice: nil),
            toolbox: LiveVoiceToolbox(sources: []), screen: nil, sendsScreenEachTurn: false, audio: nil,
            reconnectDelays: [.milliseconds(20), .milliseconds(20)]
        ) { update in
            let label = name(update)
            updates.append(label)
            signal.yield(label)
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            signal.finish()
        }
        session.start()
        for await update in stream where update == "ready" {
            readyCount += 1
            if readyCount == 2 { break }
        }
        watchdog.cancel()
        expect(server.connections == 2, "dropped socket triggered reconnect: \(server.connections)")
        expect(updates == ["ready", "reconnecting", "ready"], "dropped socket resumed cleanly: \(updates)")
        session.stop()
        server.stop()
    }

    /// Gemini toolCallCancellation cancels an in-flight tool and suppresses its toolResponse.
    static func geminiToolCancellation() async {
        guard
            let server = try? ScriptedServer(respond: { server, message in
                guard message["setup"] != nil else { return }
                server.send(["setupComplete": [String: Any]()])
                server.send([
                    "toolCall": ["functionCalls": [["id": "slow_1", "name": "slow_tool", "args": [:]]]]
                ])
                server.send(["toolCallCancellation": ["ids": ["slow_1"]]])
                server.send(["serverContent": ["turnComplete": true]])
            })
        else { return expect(false, "the scripted server starts") }
        let port = await server.start()
        let slowTool = AITool(
            name: "slow_tool", description: "Slow.",
            parameters: .object(["type": .string("object"), "properties": .object([:])]), origin: "test")
        var cancelled = false
        let list = LiveVoiceToolList(tools: [slowTool]) { call in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                cancelled = true
            }
            return AIToolResult(callID: call.id, content: "late", isError: false)
        }
        let toolbox = LiveVoiceToolbox(sources: [list])
        let (stream, signal) = AsyncStream<String>.makeStream()
        let session = LiveVoiceSession(
            wire: LoopbackGeminiWire(port: port),
            setup: LiveVoiceSetup(instructions: "Test.", tools: toolbox.tools, voice: nil),
            toolbox: toolbox, screen: nil, sendsScreenEachTurn: false, audio: nil
        ) { update in
            signal.yield(name(update))
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            signal.finish()
        }
        session.start()
        for await update in stream where update == "ended -1" {
            break
        }
        watchdog.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        expect(cancelled, "in-flight tool task was cancelled by toolCallCancellation")
        expect(!server.kinds.contains("toolResponse"), "no stale toolResponse sent after cancellation: \(server.kinds)")
        session.stop()
        server.stop()
    }

    /// Simulates VP throwing CoreAudio -10875 and verifies fallback to split capture/playback (.muted).
    static func audioVoiceProcessingFallback() async {
        let coreAudioErr = NSError(
            domain: "com.apple.coreaudio.avfaudio", code: -10_875,
            userInfo: ["failed call": "err = PerformCommand(*outputNode, kAUInitialize, NULL, 0)"])
        var vpCalls = 0
        var splitMics: [String?] = []
        let audio = LiveVoiceAudio(
            requestAccess: { true },
            openVoiceProcessed: { _, _, _, _ in
                vpCalls += 1
                throw coreAudioErr
            },
            openSplit: { _, _, uid, _ in
                splitMics.append(uid)
                if uid != nil { throw coreAudioErr }
            })
        do {
            let mode = try await audio.start(
                inputRate: 24_000, outputRate: 24_000, echo: .cancelled, microphoneUID: "BrokenUSB") { _ in }
            expect(mode == .muted, "failed VP falls back to .muted: \(mode)")
            expect(vpCalls == 1, "VP attempted once before fallback")
            expect(splitMics == ["BrokenUSB", nil], "split retries default mic after selected mic fails: \(splitMics)")
        } catch {
            expect(false, "fallback should succeed, got: \(error)")
        }

        var openVPCalls = 0
        var openSplitCalls = 0
        let headphones = LiveVoiceAudio(
            requestAccess: { true },
            openVoiceProcessed: { _, _, _, _ in openVPCalls += 1 },
            openSplit: { _, _, _, _ in openSplitCalls += 1 })
        let openMode = try? await headphones.start(inputRate: 24_000, outputRate: 24_000, echo: .open) { _ in }
        expect(openMode == .open && openVPCalls == 0 && openSplitCalls == 1, "headphones uses split directly")

        let denied = LiveVoiceAudio(requestAccess: { false })
        do {
            _ = try await denied.start(inputRate: 24_000, outputRate: 24_000, echo: .cancelled) { _ in }
            expect(false, "denied permission must throw")
        } catch let failure as LiveVoiceAudio.Failure {
            expect(failure == .microphoneDenied, "denied permission throws microphoneDenied")
        } catch {
            expect(false, "unexpected error type: \(error)")
        }
    }

    /// When both VP and split engines fail, the session emits a short readable HUD message.
    static func audioFailureMessageIsReadable() async {
        guard
            let server = try? ScriptedServer(respond: { server, message in
                if message["type"]?.stringValue == "session.update" {
                    server.send(["type": "session.updated"])
                }
            })
        else { return expect(false, "the scripted server starts") }
        let port = await server.start()
        let rawError = NSError(
            domain: "com.apple.coreaudio.avfaudio", code: -10_875,
            userInfo: ["false condition": "IsFormatSampleRateAndChannelCountValid(outputHWFormat)"])
        let audio = LiveVoiceAudio(
            requestAccess: { true },
            openVoiceProcessed: { _, _, _, _ in throw rawError },
            openSplit: { _, _, _, _ in throw rawError })
        var failedMessage: String?
        let (stream, signal) = AsyncStream<String>.makeStream()
        let session = LiveVoiceSession(
            wire: LoopbackWire(port: port),
            setup: LiveVoiceSetup(instructions: "Test.", tools: [], voice: nil),
            toolbox: LiveVoiceToolbox(sources: []), screen: nil, sendsScreenEachTurn: false,
            audio: audio, echo: .cancelled
        ) { update in
            if case .failed(let message) = update { failedMessage = message }
            signal.yield(name(update))
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            signal.finish()
        }
        session.start()
        for await update in stream where update == "closed" { break }
        watchdog.cancel()
        let message = failedMessage ?? ""
        expect(
            !message.isEmpty && !message.contains("Error Domain="),
            "audio failure message is short and readable, not raw NSError: \(message)")
        session.stop()
        server.stop()
    }

    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() async {
        await toolRoundTrip()
        await hiddenScreen()
        await refusedOpening()
        await geminiResumptionReconnect()
        await openAILifetimeReconnect()
        await socketDropReconnect()
        await manualInterrupt()
        await geminiToolCancellation()
        await audioVoiceProcessingFallback()
        await audioFailureMessageIsReadable()
        print("\(passes) passed, \(failures) failed")
        exit(failures > 0 ? 1 : 0)
    }

    /// A question, a `look_at_screen` call answered while its reply is still open, then the answer.
    static func toolRoundTrip() async {
        let server: ScriptedServer
        do {
            server = try ScriptedServer { server, message in
                let item = message["item"]?.objectValue
                switch (message["type"]?.stringValue, item?["type"]?.stringValue) {
                case ("session.update", _):
                    server.send(["type": "session.created"])
                    server.send(["type": "session.updated"])
                case ("response.create", _) where !server.received.contains("conversation.item.create:function_call_output"):
                    server.send(["type": "response.created"])
                    server.send([
                        "type": "response.output_item.done",
                        "item": ["type": "function_call", "name": "look_at_screen", "call_id": "c1", "arguments": "{}"],
                    ])
                case ("conversation.item.create", "message") where item?["role"]?.stringValue == "user"
                    && server.received.contains("conversation.item.create:function_call_output"):
                    // The picture has arrived: only now does the first reply end.
                    server.send(["type": "response.done", "response": ["status": "completed"]])
                case ("response.create", _):
                    server.send(["type": "response.created"])
                    server.send(["type": "response.output_audio_transcript.delta", "delta": "A terminal."])
                    server.send([
                        "type": "response.done",
                        "response": ["status": "completed", "usage": ["input_tokens": 10, "output_tokens": 4]],
                    ])
                default:
                    break
                }
            }
        } catch {
            expect(false, "the scripted server starts: \(error)")
            return
        }
        let port = await server.start()

        let frame = LiveVoiceFrame(pixelWidth: 100, pixelHeight: 50, display: CGRect(x: 0, y: 0, width: 200, height: 100))
        let screen = LiveVoiceScreenTools(
            capture: { LiveVoiceImage(jpeg: Data([1, 2, 3]), frame: frame) }, locate: nil, point: { _, _ in })
        let toolbox = LiveVoiceToolbox(sources: [screen])
        var updates: [String] = []
        let (stream, signal) = AsyncStream<String>.makeStream()
        let session = LiveVoiceSession(
            wire: LoopbackWire(port: port),
            setup: LiveVoiceSetup(instructions: "Test.", tools: toolbox.tools, voice: nil), toolbox: toolbox,
            screen: screen, sendsScreenEachTurn: false, audio: nil
        ) { update in
            let label = name(update)
            updates.append(label)
            signal.yield(label)
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            signal.finish()
        }
        session.start()
        for await update in stream {
            if update == "ready" { await session.ask("What is this?", withScreen: false) }
            if update == "ended 4" { break }
        }
        watchdog.cancel()

        expect(
            updates == [
                "ready", "thinking", "calling look_at_screen", "thinking", "tool look_at_screen ok",
                "ended -1", "thinking", "said A terminal.", "ended 4",
            ],
            "the session reports the call, its result and the answer: \(updates)")
        expect(
            server.kinds == [
                "session.update", "conversation.item.create:message:input_text", "response.create",
                "conversation.item.create:function_call_output", "conversation.item.create:message:input_image",
                "response.create",
            ], "the output and its picture go before the one reply that is asked for: \(server.kinds)")

        session.stop()
        expect(updates.last == "closed", "stopping closes the session")
        server.stop()
    }
}
