import Foundation

/// Encoding leaves the main actor: five minutes of speech is millions of samples.
enum VoiceMediaEncoder {
    @concurrent
    static func wav(_ samples: [Float]) async -> Data? {
        VoiceAudio.prepared(samples)
    }
}
