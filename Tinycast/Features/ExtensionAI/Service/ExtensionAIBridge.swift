import Foundation

/// Answers in flight, each read by the single `ai.read` its JS caller keeps outstanding.
@MainActor
final class ExtensionAIBridge {
    enum BridgeError: LocalizedError {
        case unknownStream

        var errorDescription: String? {
            String(localized: "This AI answer has already ended.")
        }
    }

    private final class Entry {
        let owner: ObjectIdentifier
        var task: Task<Void, Never>?
        var unread = ""
        var outcome: Result<Void, any Error>?
        var reader: CheckedContinuation<String?, any Error>?

        init(owner: ObjectIdentifier) {
            self.owner = owner
        }
    }

    private var entries: [Int: Entry] = [:]
    private var nextID = 1

    var isIdle: Bool { entries.isEmpty }

    func start(_ request: AIRequest, on provider: any AIProvider, owner: ObjectIdentifier) -> Int {
        let id = nextID
        nextID += 1
        let entry = Entry(owner: owner)
        entries[id] = entry
        entry.task = Task { [weak self] in
            var request = request
            var answered = false
            while true {
                do {
                    for try await event in provider.stream(request) {
                        guard case .text(let delta) = event, !delta.isEmpty else { continue }
                        answered = true
                        self?.deliver(delta, to: id)
                    }
                    self?.end(id, with: .success(()))
                } catch {
                    if !answered, !Task.isCancelled,
                        let retry = ExtensionAIPolicy.withoutTemperature(request, after: error)
                    {
                        request = retry
                        continue
                    }
                    self?.end(id, with: .failure(error))
                }
                return
            }
        }
        return id
    }

    /// All text since the last read, waiting for some; nil once the answer has ended.
    func read(_ id: Int, owner: ObjectIdentifier) async throws -> String? {
        guard let entry = entries[id], entry.owner == owner, entry.reader == nil else {
            throw BridgeError.unknownStream
        }
        if !entry.unread.isEmpty {
            defer { entry.unread = "" }
            return entry.unread
        }
        if let outcome = entry.outcome {
            entries[id] = nil
            try outcome.get()
            return nil
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { entry.reader = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    /// `owner` nil is the app itself; a caller's own cancel reaches only the streams it started.
    func cancel(_ id: Int, owner: ObjectIdentifier? = nil) {
        guard let entry = entries[id], owner == nil || entry.owner == owner else { return }
        entries[id] = nil
        entry.task?.cancel()
        let reader = entry.reader
        entry.reader = nil
        reader?.resume(throwing: CancellationError())
    }

    func cancelAll(owner: ObjectIdentifier? = nil) {
        for (id, entry) in entries where owner == nil || entry.owner == owner {
            cancel(id)
        }
    }

    private func deliver(_ delta: String, to id: Int) {
        guard let entry = entries[id] else { return }
        guard let reader = entry.reader else {
            entry.unread += delta
            return
        }
        entry.reader = nil
        reader.resume(returning: delta)
    }

    private func end(_ id: Int, with outcome: Result<Void, any Error>) {
        guard let entry = entries[id] else { return }
        guard let reader = entry.reader else {
            entry.outcome = outcome
            return
        }
        entries[id] = nil
        entry.reader = nil
        reader.resume(with: outcome.map { nil })
    }
}
