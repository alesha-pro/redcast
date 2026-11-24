import AppKit
import AVFoundation
import Synchronization

/// Any wire, with every reply's sound also written to a file as raw PCM16 at the output rate.
struct RecordingWire: LiveVoiceWire {
    var inner: any LiveVoiceWire
    let tape: Tape

    final class Tape: Sendable {
        private let file: Mutex<FileHandle>
        init?(path: String) {
            FileManager.default.createFile(atPath: path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
            file = Mutex(handle)
        }
        func write(_ pcm: Data) { file.withLock { try? $0.write(contentsOf: pcm) } }
    }

    var request: URLRequest { inner.request }
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
    mutating func events(from message: Data) -> [LiveVoiceEvent] {
        let events = inner.events(from: message)
        for case .audio(let pcm, _) in events { tape.write(pcm) }
        return events
    }
}

/// A hand-run stand for Live Voice: a real session from the terminal, with no app around it.
@main
@MainActor
struct LiveVoiceStand {
    static var session: LiveVoiceSession?
    static var questions: [String] = []
    static var linger = 0.0
    static var speechEnded: ContinuousClock.Instant?
    static var sendsScreenWithText = false
    static var midLine = false
    static var calledTool = false
    static let pointer = LiveVoicePointerController()

    static let usage = """
        usage: live-voice [--provider openai|gemini] [--model ID] [--voice NAME] [--effort LEVEL]
                          [--screen turn|tool|off] [--headphones] [--text QUESTION]... [--linger SECONDS]
                          [--speech AUDIOFILE]... [--silence MILLISECONDS] [--edge PIXELS]
                          [--locator MODEL|off] [--language CODE|off] [--instructions FILE]
                          [--show-prompt] [--record FILE]

          The key is read from OPENAI_API_KEY or GEMINI_API_KEY. With OPENROUTER_API_KEY set, point_at
          is offered: a vision model there finds the place the live model describes.
          --screen turn   a screenshot rides every spoken turn (the default: no round trip to look)
          --screen tool   the model asks for one with look_at_screen (two seconds slower, no picture
                          on turns that need none)
          --effort        OpenAI's reasoning effort: minimal (the default), low, medium, high
          --headphones    keep the microphone open with no echo handling; only for headphones
          --text          no microphone or speaker: send typed questions and print the replies
          --linger        seconds to stay after the last typed question, for a pointer or a task
          --speech        no microphone: play recorded questions into the session at real speed
          --silence       OpenAI's pause that ends a turn, 350 by default
          --edge          a screenshot's longest edge, 1280 by default
          --locator       the OpenRouter model that finds a pointer's target, or off
          --language      the language the user mostly speaks, as in ru; the Mac's own by default
          --instructions  a file whose text replaces the built instructions, to try a wording
          --show-prompt   print the instructions and leave
          --record        write every reply's sound to a file, as raw PCM16 mono at 24 kHz
        """

    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            let found = arguments[index + 1]
            arguments.removeSubrange(index...index + 1)
            return found
        }
        func flag(_ name: String) -> Bool {
            guard let index = arguments.firstIndex(of: name) else { return false }
            arguments.remove(at: index)
            return true
        }

        let provider = LiveVoiceProvider(rawValue: value("--provider") ?? "openai")
        let model = value("--model")
        let voice = value("--voice")
        let effort = value("--effort")
        var speech: [String] = []
        while let file = value("--speech") { speech.append(file) }
        let silence = value("--silence").flatMap(Int.init)
        let edge = value("--edge").flatMap(Int.init) ?? LiveVoiceScreenshotter.maxEdge
        let locatorModel = value("--locator") ?? LiveVoicePointLocator.defaultModel
        let locatorKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""
        let locator =
            locatorModel == "off" || locatorKey.isEmpty
            ? nil : LiveVoicePointLocator(key: locatorKey, model: locatorModel)
        let screenChoice = value("--screen") ?? "turn"
        let spoken = value("--language") ?? Locale.preferredLanguages.first ?? "off"
        let language = spoken == "off" ? nil : Locale.Language(identifier: spoken).languageCode?.identifier
        let languageName = language.flatMap { Locale(identifier: "en_US").localizedString(forLanguageCode: $0) }
        let instructionsFile = value("--instructions")
        let showsPrompt = flag("--show-prompt")
        let recording = value("--record")
        let echo: LiveVoiceAudio.Echo = flag("--headphones") ? .open : .cancelled
        linger = value("--linger").flatMap(Double.init) ?? 0
        while let question = value("--text") { questions.append(question) }
        guard let provider, arguments.isEmpty, ["turn", "tool", "off"].contains(screenChoice) else {
            print(usage)
            exit(2)
        }
        guard let key = ProcessInfo.processInfo.environment[provider.keyVariable], !key.isEmpty else {
            print("Set \(provider.keyVariable) first.")
            exit(2)
        }

        let textOnly = !questions.isEmpty || !speech.isEmpty
        sendsScreenWithText = textOnly && screenChoice == "turn"
        var locate: LiveVoiceScreenTools.Locate?
        if let locator {
            locate = { jpeg, target in
                let started = ContinuousClock.now
                let found = await locator.locate(jpeg, target)
                line("[locator] \(ContinuousClock.now - started) for: \(target)")
                return found
            }
        }
        var screen: LiveVoiceScreenTools?
        if screenChoice != "off" {
            screen = LiveVoiceScreenTools(
                offersLook: screenChoice == "tool",
                capture: { await LiveVoiceScreenshotter.capture(maxEdge: edge) }, locate: locate,
                point: { point, label in
                    line("[pointer] \(Int(point.x)),\(Int(point.y)) \(label)")
                    pointer.show(at: point, label: label)
                })
        }
        var sources: [any LiveVoiceToolSource] = [
            LiveVoiceCardTools { title, text in line("[card] \(title)\n\(text)\n[/card]") },
            LiveVoiceTaskTools { task in
                try? await Task.sleep(for: .seconds(8))
                return "This stand has no agents. It only waited eight seconds for: \(task)"
            },
        ]
        if let screen { sources.insert(screen, at: 0) }
        let toolbox = LiveVoiceToolbox(sources: sources)
        var instructions = LiveVoicePrompt.instructions(
            language: languageName ?? "", screen: screenChoice == "turn" ? .everyTurn : .onRequest,
            tools: toolbox.tools)
        if let instructionsFile {
            guard let text = try? String(contentsOfFile: instructionsFile, encoding: .utf8) else {
                print("The instructions file could not be read.")
                exit(2)
            }
            instructions = text
        }
        if showsPrompt {
            print(instructions)
            exit(0)
        }
        let setup = LiveVoiceSetup(instructions: instructions, tools: toolbox.tools, voice: voice, language: language)

        var wire = provider.wire(key: key, model: model)
        if var openAI = wire as? OpenAIRealtimeWire {
            openAI.effort = effort ?? openAI.effort
            openAI.silenceMilliseconds = silence ?? openAI.silenceMilliseconds
            wire = openAI
        }
        if let recording {
            guard let tape = RecordingWire.Tape(path: recording) else {
                print("The recording file could not be created.")
                exit(2)
            }
            wire = RecordingWire(inner: wire, tape: tape)
        }
        let recordings = speech.compactMap { samples(of: $0, rate: wire.inputRate) }
        if recordings.count != speech.count {
            print("An audio file could not be read.")
            exit(2)
        }
        let session = LiveVoiceSession(
            wire: wire, setup: setup, toolbox: toolbox, screen: screen,
            sendsScreenEachTurn: questions.isEmpty && screenChoice == "turn",
            audio: textOnly ? nil : LiveVoiceAudio(),
            echo: echo, onUpdate: show)
        Self.session = session
        Self.recordings = recordings
        Self.speaks = !recordings.isEmpty
        Self.chunkBytes = wire.inputRate / 50 * 2

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { exit(0) }
        interrupt.resume()

        line(
            "[connecting] \(provider.rawValue) \(model ?? provider.defaultModel), screen: \(screenChoice), "
                + "pointer: \(locator?.model ?? "off"), language: \(languageName ?? "any")")
        if screenChoice != "off", !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            line("[screen] this terminal may not record the screen, so the model sees nothing and cannot point.")
            line("         Allow it in System Settings > Privacy & Security > Screen & System Audio Recording,")
            line("         then quit the terminal and open it again.")
        }
        session.start()
        withExtendedLifetime(interrupt) { application.run() }
    }

    static func show(_ update: LiveVoiceSession.Update) {
        switch update {
        case .ready:
            line("[ready]")
            if speaks { Task { await speak() } }
            askNext()
        case .listening(let echo):
            switch echo {
            case .cancelled: line("[listening] echo cancelled by macOS: talk over a reply to cut it; Ctrl-C ends")
            case .muted:
                line("[listening] macOS would not cancel echo on these devices, so the microphone is deaf while")
                line("            a reply plays. On headphones, run with --headphones to cut in by voice.")
            case .open: line("[listening] microphone always open (headphones); Ctrl-C ends")
            }
        case .userSpeaking, .thinking, .speaking:
            break
        case .reconnecting:
            line("[reconnecting]")
        case .heard(let text):
            line("you: \(text)")
        case .said(let text):
            if !midLine { print("ai: ", terminator: "") }
            print(text, terminator: "")
            fflush(stdout)
            midLine = true
        case .latency(let seconds):
            line(String(format: "[latency] %.2f s from the provider noticing the pause to first sound", seconds))
            if let speechEnded {
                let whole = ContinuousClock.now - speechEnded
                let total = Double(whole.components.seconds) + Double(whole.components.attoseconds) / 1e18
                line(String(format: "[latency] %.2f s from the last recorded word to first sound", total))
                Self.speechEnded = nil
            }
        case .calling:
            calledTool = true
        case .tool(let call, let result):
            line("[tool] \(call.name)(\(call.arguments)) -> \(result.isError ? "ERROR " : "")\(result.content)")
        case .replyEnded(let usage):
            if let usage {
                line("[usage] in \(usage.input) (cached \(usage.cached)), out \(usage.output)")
            } else {
                line("")
            }
            let finishedAnAnswer = !calledTool
            calledTool = false
            if finishedAnAnswer { askNext() }
        case .failed(let message):
            line("[error] \(message)")
        case .closed:
            line("[closed]")
            exit(0)
        }
    }

    static var recordings: [Data] = []
    static var speaks = false
    static var speaking: Data?
    static var chunkBytes = 960

    /// Each recording at real speed, and silence between them, as an open microphone gives.
    static func speak() async {
        guard let session else { return }
        let clock = ContinuousClock()
        var next = clock.now
        var offset = 0
        while true {
            if let recorded = speaking, offset < recorded.count {
                session.hear(recorded.subdata(in: offset..<min(offset + chunkBytes, recorded.count)))
                offset += chunkBytes
                if offset >= recorded.count {
                    speechEnded = .now
                    speaking = nil
                    offset = 0
                }
            } else {
                session.hear(Data(count: chunkBytes))
            }
            next += .milliseconds(20)
            try? await clock.sleep(until: next)
        }
    }

    /// Any audio file as PCM16 mono at `rate`.
    static func samples(of path: String, rate: Int) -> Data? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
            let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: file.processingFormat, to: target),
            let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
            (try? file.read(into: input)) != nil
        else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var pending: AVAudioPCMBuffer? = input
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, state in
            guard let buffer = pending else {
                state.pointee = .endOfStream
                return nil
            }
            pending = nil
            state.pointee = .haveData
            return buffer
        }
        guard let samples = output.int16ChannelData?[0], output.frameLength > 0 else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }

    /// Typed questions go one at a time, each after the reply before it has ended.
    static func askNext() {
        guard let session else { return }
        if !recordings.isEmpty {
            speaking = recordings.removeFirst()
            line("[speaking] a recorded question")
            return
        }
        guard !questions.isEmpty else {
            guard CommandLine.arguments.contains("--text") || speaks else { return }
            Task {
                try? await Task.sleep(for: .seconds(linger))
                session.stop()
            }
            return
        }
        let question = questions.removeFirst()
        line("you (typed): \(question)")
        Task { await session.ask(question, withScreen: sendsScreenWithText) }
    }

    static func line(_ text: String) {
        if midLine { print() }
        midLine = false
        print(text)
        fflush(stdout)
    }
}
