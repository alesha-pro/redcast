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

    /// A route that takes less output than the round asked for names the field, or the room it asked.
    static func refusesOutputCap(_ error: any Error) -> Bool {
        if let failure = error as? AIProviderRecoverableError, failure.kind != .overflow { return false }
        let said = error.localizedDescription.lowercased()
        return capWords.contains(where: said.contains)
    }

    /// A strict gateway naming a reasoning field it does not take, which the run then stops sending.
    static func refusesReasoning(_ error: any Error) -> Bool {
        guard !(error is AIProviderRecoverableError) else { return false }
        let said = error.localizedDescription.lowercased()
        // `reasoning`, `reasoning_content` or `reasoning_details`, never `reasoning_effort`.
        guard said.contains(/\breasoning(_content|_details)?\b/) else { return false }
        return refusalWords.contains(where: said.contains)
    }

    /// Groq's, Mistral's, OpenAI's and pydantic's words for a field a schema does not know.
    private static let refusalWords = [
        "unsupported", "not supported", "unrecognized", "unexpected", "unknown", "not permitted",
        "not allowed", "extra_forbidden", "extra inputs", "additional properties"
    ]

    /// vLLM's, SGLang's, OpenRouter's, OpenAI's and Anthropic's words for output that does not fit.
    private static let capWords = [
        "max_tokens", "max_completion_tokens", "max_output_tokens", "maximum allowed number of output",
        "in the completion", "for the completion", "in the output"
    ]
}
