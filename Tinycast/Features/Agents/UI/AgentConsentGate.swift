import Foundation
import Observation

/// Agent questions one at a time and never over another dialog, which would refuse them unseen.
@MainActor
final class AgentConsentGate {
    private var isBusy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    /// Whether a question is up or waiting its turn; nothing is held while this is false.
    var isIdle: Bool { !isBusy && queue.isEmpty }

    /// Waits its turn, then for any open dialog to close, observed rather than polled.
    func run<T>(dialogIsUp: @escaping @MainActor () -> Bool, _ ask: () async -> T) async -> T {
        if isBusy {
            await withCheckedContinuation { queue.append($0) }
        }
        isBusy = true
        defer { handOver() }
        while dialogIsUp() {
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = dialogIsUp()
                } onChange: {
                    continuation.resume()
                }
            }
        }
        return await ask()
    }

    /// The next question inherits the turn, so a newcomer can never slip in between the two.
    private func handOver() {
        guard !queue.isEmpty else {
            isBusy = false
            return
        }
        queue.removeFirst().resume()
    }
}
