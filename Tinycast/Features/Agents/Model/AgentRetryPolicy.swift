import Foundation

/// How a run outlasts a provider's bad minute: which failures to try again, and after how long.
struct AgentRetryPolicy: Sendable {
    /// pi's 2, 4, 8 s and dsh's fourth, about half a minute in all: past that the route is down.
    static let standard = AgentRetryPolicy(
        delays: [2, 4, 8, 16].map { Duration.seconds($0) }, jitter: 0.1, longestWait: .seconds(60))

    let delays: [Duration]
    /// A share either way, so runs that failed together do not all come back at once.
    let jitter: Double
    /// A Retry-After past this is a route that is down for a while, not a busy one.
    let longestWait: Duration

    var attempts: Int { delays.count }

    /// The wait before retry `number` (from 1), or nil when the failure should stand.
    func delay(before number: Int, after error: any Error, random: Double) -> Duration? {
        guard number >= 1, number <= delays.count,
            let failure = error as? AIProviderRecoverableError,
            case .transient(let retryAfter) = failure.kind
        else { return nil }
        let spread = 1 + jitter * (random * 2 - 1)
        let backoff = delays[number - 1] * spread
        guard let retryAfter else { return backoff }
        guard retryAfter <= longestWait else { return nil }
        return max(retryAfter, backoff)
    }

    /// The row a waiting round shows, so a pause reads as a retry rather than a hang.
    static func title(_ number: Int, of count: Int) -> String {
        String(localized: "Retrying after a provider error (\(number) of \(count))")
    }

    static func isOverflow(_ error: any Error) -> Bool {
        (error as? AIProviderRecoverableError)?.kind == .overflow
    }

    /// A route whose model takes less output than the round asked for names the field it refused.
    static func refusesOutputCap(_ error: any Error) -> Bool {
        guard !(error is AIProviderRecoverableError) else { return false }
        let said = error.localizedDescription.lowercased()
        return ["max_tokens", "max_completion_tokens", "max_output_tokens", "maximum allowed number of output"]
            .contains(where: said.contains)
    }
}
