import Foundation

/// What leaves the Mac: speech only, trimmed, as 16-bit mono WAV built in memory.
enum VoiceAudio {
    static let sampleRate = 16_000
    /// 20 ms windows: a word's onset survives, a click does not.
    static let windowSamples = 320
    /// Below this RMS (about −40 dBFS) a recording holds no speech at all.
    static let speechPeakRMS: Float = 0.01
    static let silenceFloorRMS: Float = 0.003
    static let relativeThreshold: Float = 0.08
    static let minimumSpeechWindows = 10
    static let paddingWindows = 15
    static let headerBytes = 44

    /// nil when nothing in the recording is speech.
    static func speechRange(in samples: [Float]) -> Range<Int>? {
        let windowCount = samples.count / windowSamples
        guard windowCount >= minimumSpeechWindows else { return nil }
        let levels = samples.withUnsafeBufferPointer { buffer in
            (0..<windowCount).map { rms(buffer[($0 * windowSamples)..<(($0 + 1) * windowSamples)]) }
        }
        guard let peak = levels.max(), peak >= speechPeakRMS else { return nil }
        let threshold = max(silenceFloorRMS, peak * relativeThreshold)
        guard levels.count(where: { $0 >= threshold }) >= minimumSpeechWindows,
            let first = levels.firstIndex(where: { $0 >= threshold }),
            let last = levels.lastIndex(where: { $0 >= threshold })
        else { return nil }
        let start = max(0, first - paddingWindows) * windowSamples
        let endWindow = last + 1 + paddingWindows
        return start..<(endWindow >= windowCount ? samples.count : endWindow * windowSamples)
    }

    /// RIFF/WAVE, fmt PCM=1, 1 channel, 16-bit LE; NaN → 0, clamps to ±1, scales by 32 767.
    static func wav(_ samples: ArraySlice<Float>, sampleRate: Int = sampleRate) -> Data {
        let dataBytes = samples.count * MemoryLayout<Int16>.size
        var data = Data(capacity: headerBytes + dataBytes)
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        var pcm = [Int16]()
        pcm.reserveCapacity(samples.count)
        for sample in samples { pcm.append(pcm16(sample).littleEndian) }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Gate then encode; nil means "No speech was recorded" without touching the network.
    static func prepared(_ samples: [Float]) -> Data? {
        speechRange(in: samples).map { wav(samples[$0]) }
    }

    private static func pcm16(_ sample: Float) -> Int16 {
        guard !sample.isNaN else { return 0 }
        return Int16((min(max(sample, -1), 1) * 32_767).rounded())
    }

    private static func rms(_ window: Slice<UnsafeBufferPointer<Float>>) -> Float {
        var sum: Float = 0
        for sample in window where sample.isFinite { sum += sample * sample }
        return (sum / Float(window.count)).squareRoot()
    }
}
