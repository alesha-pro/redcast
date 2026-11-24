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

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection?.send(content: data, contentContext: context, completion: .idempotent)
    }

    func stop() {
        connection?.cancel()
        listener.cancel()
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [self] data, _, _, error in
            guard error == nil, let data, let message = JSONValue(data: data)?.objectValue else { return }
            let type = message["type"]?.stringValue ?? "?"
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
            screen: screen, sendsScreenEachTurn: false, audio: nil
        ) { update in
            updates.append(name(update))
            signal.yield(name(update))
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
            run.updates == ["ready", "failed \(LiveVoiceSession.hiddenScreen)", "ended -1"],
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
            let name: String
            switch update {
            case .ready: name = "ready"
            case .listening: name = "listening"
            case .heard(let text): name = "heard \(text)"
            case .said(let text): name = "said \(text)"
            case .replyEnded(let usage): name = "ended \(usage?.output ?? -1)"
            case .latency: name = "latency"
            case .calling(let call): name = "calling \(call.name)"
            case .tool(let call, let result): name = "tool \(call.name) \(result.isError ? "error" : "ok")"
            case .failed(let message): name = "failed \(message)"
            case .closed: name = "closed"
            }
            updates.append(name)
            signal.yield(name)
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
            updates == ["ready", "calling look_at_screen", "tool look_at_screen ok", "ended -1", "said A terminal.", "ended 4"],
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
