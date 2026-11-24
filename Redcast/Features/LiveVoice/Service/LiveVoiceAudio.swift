import AVFoundation
import Synchronization

/// The microphone and the speaker on one engine, so macOS can cancel the speaker out of the mic.
@MainActor
final class LiveVoiceAudio {
    enum Failure: Error {
        case microphoneDenied
        case noInput
    }

    /// What keeps the assistant from hearing itself and taking that for the user cutting in.
    enum Echo: Sendable {
        /// macOS removes the speaker from the microphone, so the user can talk over a reply.
        case cancelled
        /// The microphone is deaf while a reply plays: no voice processing on these devices.
        case muted
        /// Nothing is done, which is right for headphones.
        case open
    }

    /// A room keeps a reply audible a moment after its last sample.
    private static let muteTail: Duration = .milliseconds(250)

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var playback: AVAudioFormat?
    private let gate = MicrophoneGate()
    private var echo = Echo.open
    /// What is queued, in player frames, so a cut can name the item playing and how far it got.
    private var queued: [Stretch] = []

    private struct Stretch {
        let item: String
        let start: AVAudioFramePosition
        var end: AVAudioFramePosition
    }

    /// Answers the echo handling in effect; `onInput` gets PCM16 mono at `inputRate` on the audio thread.
    func start(
        inputRate: Int, outputRate: Int, echo wanted: Echo, onInput: @escaping @Sendable (Data) -> Void
    ) async throws -> Echo {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.microphoneDenied }
        let gate = gate
        let gated: @Sendable (Data) -> Void = { pcm in
            if let until = gate.mutedUntil.withLock({ $0 }), ContinuousClock.now < until { return }
            onInput(pcm)
        }
        if wanted == .cancelled {
            do {
                try open(inputRate: inputRate, outputRate: outputRate, processesVoice: true, onInput: gated)
                echo = .cancelled
                return echo
            } catch {
                // A failed voice-processing unit leaves its engine unusable.
                engine = AVAudioEngine()
                player = AVAudioPlayerNode()
            }
        }
        try open(inputRate: inputRate, outputRate: outputRate, processesVoice: false, onInput: gated)
        echo = wanted == .open ? .open : .muted
        return echo
    }

    private func open(
        inputRate: Int, outputRate: Int, processesVoice: Bool, onInput: @escaping @Sendable (Data) -> Void
    ) throws {
        let input = engine.inputNode
        if processesVoice {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min)
        }
        let microphone = input.outputFormat(forBus: 0)
        guard
            let playback = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(outputRate), channels: 1,
                interleaved: false),
            let wire = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Double(inputRate), channels: 1,
                interleaved: true),
            microphone.sampleRate > 0,
            let sink = MicrophoneSink(from: microphone, to: wire, onInput)
        else { throw Failure.noInput }
        self.playback = playback
        let receiver = sink.node
        engine.attach(player)
        engine.attach(receiver)
        try connect(player, to: engine.mainMixerNode, format: playback)
        try connect(input, to: receiver, format: microphone)
        engine.prepare()
        try engine.start()
        try resume()
    }

    func play(_ pcm: Data, of item: String) throws {
        guard let playback, let buffer = Self.buffer(pcm, format: playback) else { return }
        if !player.isPlaying { try resume() }
        let now = playerFrames
        queued.removeAll { $0.end <= now }
        let frames = AVAudioFramePosition(buffer.frameLength)
        if let last = queued.indices.last, queued[last].item == item {
            queued[last].end += frames
        } else {
            let start = max(now, queued.last?.end ?? 0)
            queued.append(Stretch(item: item, start: start, end: start + frames))
        }
        player.scheduleBuffer(buffer)
        guard echo == .muted, let end = queued.last?.end else { return }
        let left = Duration.seconds(Double(end - now) / playback.sampleRate)
        gate.mutedUntil.withLock { $0 = .now + left + Self.muteTail }
    }

    /// Drops what is queued; answers the item that was playing and how much of it was heard.
    func interrupt() -> (item: String, milliseconds: Int)? {
        let now = playerFrames
        let playing = queued.first { $0.end > now }
        player.stop()
        queued = []
        gate.mutedUntil.withLock { $0 = nil }
        guard let playback, let playing else { return nil }
        let heard = max(now - playing.start, 0)
        return (playing.item, Int(Double(heard) / playback.sampleRate * 1_000))
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    private func connect(_ source: AVAudioNode, to destination: AVAudioNode, format: AVAudioFormat) throws {
        if #available(macOS 27, *) {
            try engine.connectNode(source, to: destination, format: format)
        } else {
            engine.connect(source, to: destination, format: format)
        }
    }

    private func resume() throws {
        if #available(macOS 27, *) {
            try player.playAudio()
        } else {
            player.play()
        }
    }

    private var playerFrames: AVAudioFramePosition {
        guard let rendered = player.lastRenderTime, let time = player.playerTime(forNodeTime: rendered)
        else { return 0 }
        return time.sampleTime
    }

    private static func buffer(_ pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = pcm.count / MemoryLayout<Int16>.size
        guard frames > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let samples = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            for index in 0..<frames {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                samples[index] = Float(sample) / Float(Int16.max)
            }
        }
        return buffer
    }
}

/// Until when the microphone is deaf, read on the audio thread and set on the main one.
private final class MicrophoneGate: Sendable {
    let mutedUntil = Mutex<ContinuousClock.Instant?>(nil)
}

/// The capture callback's state: touched only on the audio thread that feeds the sink.
private final class MicrophoneSink: @unchecked Sendable {
    /// A chunk of 20 ms reaches the provider sooner than a tap's 100 ms, without a message per render.
    private static let chunkSeconds = 0.02

    private let converter: AVAudioConverter
    private let source: AVAudioFormat
    private let target: AVAudioFormat
    private let chunkBytes: Int
    private let onInput: @Sendable (Data) -> Void
    private var pending = Data()

    init?(from source: AVAudioFormat, to target: AVAudioFormat, _ onInput: @escaping @Sendable (Data) -> Void) {
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        // Voice processing reports a microphone array; its first channel is the processed voice.
        if source.channelCount > 1 { converter.channelMap = [0] }
        self.converter = converter
        self.source = source
        self.target = target
        self.onInput = onInput
        chunkBytes = Int(target.sampleRate * Self.chunkSeconds) * MemoryLayout<Int16>.size
    }

    var node: AVAudioSinkNode {
        AVAudioSinkNode { [self] _, _, buffers in
            receive(buffers)
            return noErr
        }
    }

    private func receive(_ buffers: UnsafePointer<AudioBufferList>) {
        guard let input = AVAudioPCMBuffer(pcmFormat: source, bufferListNoCopy: buffers), input.frameLength > 0
        else { return }
        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var next: AVAudioPCMBuffer? = input
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            guard let buffer = next else {
                state.pointee = .noDataNow
                return nil
            }
            next = nil
            state.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        pending.append(
            UnsafeBufferPointer(start: samples, count: Int(output.frameLength)).withMemoryRebound(to: UInt8.self) {
                Data($0)
            })
        guard pending.count >= chunkBytes else { return }
        onInput(pending)
        pending = Data()
    }
}
