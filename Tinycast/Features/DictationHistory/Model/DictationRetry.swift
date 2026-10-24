import Foundation

/// What a retry tries: the engine, the model and the mode, as the entry will name them.
struct DictationRetryAttempt: Equatable, Sendable {
    let engine: DictationHistoryEntry.Engine
    let model: String?
    var mode: String?
    var modeID: UUID?
}

/// What a retry heard: the text to keep and how it was made.
struct DictationRetryTranscript: Equatable, Sendable {
    let text: String
    var transcript: String?
    var mode: String?
    let engine: DictationHistoryEntry.Engine
    let model: String
}

enum DictationRetryFailure: LocalizedError, Equatable {
    case noRecording
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .noRecording: String(localized: "The recording is no longer kept.")
        case .noSpeech: String(localized: "No speech was heard in the recording.")
        }
    }
}

/// The retries running while the screen is open: one per entry, and only its latest attempt lands.
struct DictationRetryState: Equatable, Sendable {
    private var attempts: [UUID: UUID] = [:]

    var isIdle: Bool { attempts.isEmpty }

    func isRetrying(_ id: UUID) -> Bool { attempts[id] != nil }

    /// nil while that entry already has one running.
    mutating func begin(_ id: UUID) -> UUID? {
        guard attempts[id] == nil else { return nil }
        let attempt = UUID()
        attempts[id] = attempt
        return attempt
    }

    /// Whether `attempt` is still the entry's, so its result may land; either way it is over.
    mutating func end(_ id: UUID, attempt: UUID) -> Bool {
        guard attempts[id] == attempt else { return false }
        attempts[id] = nil
        return true
    }

    /// A deleted entry, or a closed screen, drops whatever its attempts still bring.
    mutating func cancel(_ ids: Set<UUID>) {
        for id in ids { attempts[id] = nil }
    }

    mutating func cancelAll() {
        attempts = [:]
    }
}

/// One retry of a kept recording, from its samples to what the entry becomes.
enum DictationRetry {
    /// nil when the retry was cancelled, so the entry stays exactly as it was.
    @MainActor
    static func run(
        _ entry: DictationHistoryEntry, samples: [Float]?, attempt: DictationRetryAttempt,
        transcribe: @MainActor ([Float]) async throws -> DictationRetryTranscript,
        describe: @MainActor (any Error) -> String
    ) async -> DictationHistoryEntry? {
        guard let samples else {
            return entry.failed(describe(DictationRetryFailure.noRecording), on: attempt)
        }
        do {
            let heard = try await transcribe(samples)
            guard !Task.isCancelled else { return nil }
            let text = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return entry.failed(describe(DictationRetryFailure.noSpeech), on: attempt)
            }
            return entry.transcribed(
                DictationRetryTranscript(
                    text: text, transcript: heard.transcript, mode: heard.mode, engine: heard.engine,
                    model: heard.model))
        } catch {
            guard !Task.isCancelled, !isCancellation(error) else { return nil }
            return entry.failed(describe(error), on: attempt)
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
