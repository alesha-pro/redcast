import Foundation
import Synchronization

/// What the user sends while a run works: taken at the run's next step boundary, as pi and dsh steer.
final class AgentSteering: Sendable {
    private struct State {
        var open = true
        var pending: [String] = []
    }

    private let state = Mutex(State())

    /// False once the run is over, so the caller sends the text as a turn of its own instead.
    func push(_ text: String) -> Bool {
        state.withLock { state in
            guard state.open else { return false }
            state.pending.append(text)
            return true
        }
    }

    /// Everything waiting, oldest first; the loop hands it to the model as one user message.
    func take() -> [String] {
        state.withLock { state in
            defer { state.pending = [] }
            return state.pending
        }
    }

    /// The run ended: nothing more is taken, and what it never delivered goes back to the caller.
    func close() -> [String] {
        state.withLock { state in
            state.open = false
            defer { state.pending = [] }
            return state.pending
        }
    }

    /// The row a delivered message shows in the reply, one line and short.
    static func title(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let shown = line.count <= 120 ? line : String(line.prefix(119)) + "…"
        return String(localized: "You added: \(shown)")
    }
}
