import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio
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
    static let spectrumBarCount = 21

    var onLevels: (@MainActor ([Float]) -> Void)?
    var onSpeakingChanged: (@MainActor (Bool) -> Void)?

    var isMuted: Bool {
        get { gate.isUserMuted.withLock { $0 } }
        set { gate.isUserMuted.withLock { $0 = newValue } }
    }

    private(set) var isSpeaking = false

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var voiceProcessingActive = false
    private var playback: AVAudioFormat?
    private let gate = MicrophoneGate()
    private var echo = Echo.open
    private var playbackGeneration = 0
    private var pendingBuffers = 0
    private var outputMeter: LevelMeter?
    /// What is queued, in player frames, so a cut can name the item playing and how far it got.
    private var queued: [Stretch] = []

    private struct Stretch {
        let item: String
        let start: AVAudioFramePosition
        var end: AVAudioFramePosition
    }

    isolated deinit {
        stop()
    }

    /// Answers the echo handling in effect; `onInput` gets PCM16 mono at `inputRate` on the audio thread.
    func start(
        inputRate: Int, outputRate: Int, echo wanted: Echo, microphoneUID: String? = nil,
        onInput: @escaping @Sendable (Data) -> Void
    ) async throws -> Echo {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.microphoneDenied }
        stop()
        let gate = gate
        let inputMeter: LevelMeter?
        if onLevels != nil {
            inputMeter = LevelMeter(barCount: Self.spectrumBarCount) { [weak self] levels in
                Task { @MainActor [weak self] in
                    guard let self, !self.isSpeaking else { return }
                    self.onLevels?(levels)
                }
            }
            outputMeter = LevelMeter(barCount: Self.spectrumBarCount) { [weak self] levels in
                Task { @MainActor [weak self] in
                    guard let self, self.isSpeaking else { return }
                    self.onLevels?(levels)
                }
            }
        } else {
            inputMeter = nil
        }
        let gated: @Sendable (Data) -> Void = { pcm in
            if gate.isUserMuted.withLock({ $0 }) { return }
            if let until = gate.mutedUntil.withLock({ $0 }), ContinuousClock.now < until { return }
            inputMeter?.feed(pcm16: pcm)
            onInput(pcm)
        }
        if wanted == .cancelled {
            do {
                try open(
                    inputRate: inputRate, outputRate: outputRate, processesVoice: true,
                    microphoneUID: microphoneUID, onInput: gated)
                echo = .cancelled
                return echo
            } catch {
                // A failed voice-processing unit leaves its engine unusable and may have ducked audio.
                teardownEngine()
            }
        }
        try open(
            inputRate: inputRate, outputRate: outputRate, processesVoice: false,
            microphoneUID: microphoneUID, onInput: gated)
        echo = wanted == .open ? .open : .muted
        return echo
    }

    private func open(
        inputRate: Int, outputRate: Int, processesVoice: Bool, microphoneUID: String?,
        onInput: @escaping @Sendable (Data) -> Void
    ) throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        self.engine = engine
        self.player = player
        let input = engine.inputNode
        if let microphoneUID, !microphoneUID.isEmpty {
            Self.selectInputDevice(uid: microphoneUID, on: input)
        }
        if processesVoice {
            try input.setVoiceProcessingEnabled(true)
            voiceProcessingActive = true
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
        try connect(engine, player, to: engine.mainMixerNode, format: playback)
        try connect(engine, input, to: receiver, format: microphone)
        engine.prepare()
        try engine.start()
        try resume(player)
    }

    func play(_ pcm: Data, of item: String) throws {
        guard let player, let playback, let buffer = Self.buffer(pcm, format: playback) else { return }
        if !player.isPlaying { try resume(player) }
        let now = playerFrames
        queued.removeAll { $0.end <= now }
        let frames = AVAudioFramePosition(buffer.frameLength)
        if let last = queued.indices.last, queued[last].item == item {
            queued[last].end += frames
        } else {
            let start = max(now, queued.last?.end ?? 0)
            queued.append(Stretch(item: item, start: start, end: start + frames))
        }
        pendingBuffers += 1
        setSpeaking(true)
        outputMeter?.feed(pcm16: pcm)
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                if self.pendingBuffers == 0 { self.setSpeaking(false) }
            }
        }
        guard echo == .muted, let end = queued.last?.end else { return }
        let left = Duration.seconds(Double(end - now) / playback.sampleRate)
        gate.mutedUntil.withLock { $0 = .now + left + Self.muteTail }
    }

    /// Drops what is queued; answers the item that was playing and how much of it was heard.
    func interrupt() -> (item: String, milliseconds: Int)? {
        let now = playerFrames
        let playing = queued.first { $0.end > now }
        playbackGeneration &+= 1
        pendingBuffers = 0
        player?.stop()
        queued = []
        gate.mutedUntil.withLock { $0 = nil }
        setSpeaking(false)
        guard let playback, let playing else { return nil }
        let heard = min(max(now - playing.start, 0), playing.end - playing.start)
        return (playing.item, Int(Double(heard) / playback.sampleRate * 1_000))
    }

    func stop() {
        playbackGeneration &+= 1
        pendingBuffers = 0
        teardownEngine()
        playback = nil
        outputMeter = nil
        queued = []
        gate.mutedUntil.withLock { $0 = nil }
        gate.isUserMuted.withLock { $0 = false }
        setSpeaking(false)
    }

    private func teardownEngine() {
        player?.stop()
        if let engine {
            engine.stop()
            if voiceProcessingActive {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
                voiceProcessingActive = false
            }
            engine.reset()
        }
        player = nil
        engine = nil
    }

    private func setSpeaking(_ speaking: Bool) {
        guard isSpeaking != speaking else { return }
        isSpeaking = speaking
        onSpeakingChanged?(speaking)
    }

    private static func selectInputDevice(uid: String, on input: AVAudioInputNode) {
        guard let device = try? AudioHardwareSystem.shared.device(forUID: uid) else { return }
        var deviceID = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if #available(macOS 27, *) {
            input.withAudioUnit { unit in
                guard let unit else { return }
                _ = AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &deviceID, size)
            }
        } else if let unit = input.audioUnit {
            _ = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
                size)
        }
    }

    private func connect(
        _ engine: AVAudioEngine, _ source: AVAudioNode, to destination: AVAudioNode,
        format: AVAudioFormat
    ) throws {
        if #available(macOS 27, *) {
            try engine.connectNode(source, to: destination, format: format)
        } else {
            engine.connect(source, to: destination, format: format)
        }
    }

    private func resume(_ player: AVAudioPlayerNode) throws {
        if #available(macOS 27, *) {
            try player.playAudio()
        } else {
            player.play()
        }
    }

    private var playerFrames: AVAudioFramePosition {
        guard let player, let rendered = player.lastRenderTime,
            let time = player.playerTime(forNodeTime: rendered)
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

/// Shared between audio thread (reads) and main actor (writes) without blocking.
private final class MicrophoneGate: Sendable {
    let mutedUntil = Mutex<ContinuousClock.Instant?>(nil)
    let isUserMuted = Mutex<Bool>(false)
}

/// Lightweight 21-bar spectrum meter for live voice waveforms, throttled to ~20 Hz.
private final class LevelMeter: Sendable {
    private struct State {
        let transform: vDSP.DiscreteFourierTransform<Float>?
        var displayed: [Float]
        var lastEmit: ContinuousClock.Instant = .now - .seconds(1)
        var real: [Float]
        let imaginary: [Float]
        var outReal: [Float]
        var outImaginary: [Float]
    }

    private static let sampleCount = 256
    private let state: Mutex<State>
    private let window: [Float]
    private let bands: [Range<Int>]
    private let onLevels: @Sendable ([Float]) -> Void

    init(barCount: Int, onLevels: @escaping @Sendable ([Float]) -> Void) {
        self.onLevels = onLevels
        let transform = try? vDSP.DiscreteFourierTransform(
            count: Self.sampleCount, direction: .forward, transformType: .complexComplex,
            ofType: Float.self)
        window = (0..<Self.sampleCount).map {
            0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(Self.sampleCount - 1))
        }
        let edges = (0...barCount).map {
            Int(
                32 * pow(5000.0 / 32, Double($0) / Double(barCount)) * Double(Self.sampleCount)
                    / 16_000)
        }
        bands = (0..<barCount).map {
            min(edges[$0], Self.sampleCount / 2 - 1)..<min(max(edges[$0] + 1, edges[$0 + 1]), Self.sampleCount / 2)
        }
        state = Mutex(
            State(
                transform: transform,
                displayed: [Float](repeating: 0, count: barCount),
                real: [Float](repeating: 0, count: Self.sampleCount),
                imaginary: [Float](repeating: 0, count: Self.sampleCount),
                outReal: [Float](repeating: 0, count: Self.sampleCount),
                outImaginary: [Float](repeating: 0, count: Self.sampleCount)))
    }

    func feed(pcm16: Data) {
        let count = pcm16.count / MemoryLayout<Int16>.size
        guard count > 0 else { return }
        let emitted: [Float]? = state.withLock { state in
            guard let transform = state.transform else { return nil }
            let now = ContinuousClock.now
            guard now - state.lastEmit >= .milliseconds(50) else { return nil }
            state.lastEmit = now
            let start = max(0, count - Self.sampleCount)
            let take = count - start
            pcm16.withUnsafeBytes { raw in
                for index in 0..<Self.sampleCount {
                    if index < take {
                        let sample = Int16(
                            littleEndian: raw.loadUnaligned(
                                fromByteOffset: (start + index) * 2, as: Int16.self))
                        state.real[index] = (Float(sample) / Float(Int16.max)) * window[index]
                    } else {
                        state.real[index] = 0
                    }
                }
            }
            transform.transform(
                inputReal: state.real, inputImaginary: state.imaginary,
                outputReal: &state.outReal, outputImaginary: &state.outImaginary)
            for (index, band) in bands.enumerated() {
                let energy = band.reduce(Float(0)) {
                    $0 + state.outReal[$1] * state.outReal[$1] + state.outImaginary[$1] * state.outImaginary[$1]
                }
                let amplitude = sqrt(energy) / Float(Self.sampleCount)
                let level = max(0, (sqrt(amplitude) - 0.025) * 15)
                let target = level / sqrt(1 + level * level)
                let response: Float = target > state.displayed[index] ? 0.6 : 0.25
                state.displayed[index] += (target - state.displayed[index]) * response
            }
            return state.displayed
        }
        if let emitted { onLevels(emitted) }
    }
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
