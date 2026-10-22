import Foundation

@main
@MainActor
struct UsageDashboardTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() async {
        await aToolLoopTurnCostsEveryRound()
        onlyOpenAIIsAskedForStreamUsage()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Accuracy fixes

    static func aToolLoopTurnCostsEveryRound() async {
        let call = AIToolCall(id: "c1", name: "fs__read", arguments: "{}")
        let summed = await lastUsage([
            [.usage(AIUsage(inputTokens: 10, outputTokens: 5, costUSD: 0.01)), .toolCallRequested(call)],
            [.text("done"), .usage(AIUsage(inputTokens: 30, outputTokens: 7, costUSD: 0.02)), .finished]
        ])
        expect(abs((summed.last?.costUSD ?? 0) - 0.03) < 1e-12, "the reply's cost is every round's")
        expect(
            summed.last?.inputTokens == 30 && summed.last?.outputTokens == 7,
            "its tokens stay the last round's, which is what the window holds")
        expect(summed.first?.costUSD == 0.01, "the first round passes its own cost through")

        let unpricedRound = await lastUsage([
            [.usage(AIUsage(inputTokens: 10, costUSD: 0.01)), .toolCallRequested(call)],
            [.usage(AIUsage(inputTokens: 20)), .finished]
        ])
        expect(unpricedRound.last?.costUSD == 0.01, "a round without cost keeps the running sum")

        let unpriced = await lastUsage([
            [.usage(AIUsage(inputTokens: 10)), .toolCallRequested(call)],
            [.usage(AIUsage(inputTokens: 20)), .finished]
        ])
        expect(unpriced.last != nil && unpriced.last?.costUSD == nil, "a route that never prices stays unpriced")
    }

    private static func lastUsage(_ rounds: [[AIStreamEvent]]) async -> [AIUsage] {
        let loop = AIToolLoopProvider(
            base: Rounds(rounds),
            tools: [AITool(name: "fs__read", description: "", parameters: .object([:]), origin: "Files")],
            maxRounds: 10,
            invoke: { AIToolResult(callID: $0.id, content: "ok", isError: false) })
        var usages: [AIUsage] = []
        do {
            for try await event in loop.stream(AIRequest(messages: [AIMessage(role: .user, text: "go")])) {
                if case .usage(let usage) = event { usages.append(usage) }
            }
        } catch {
            expect(false, "the scripted turn finishes: \(error)")
        }
        return usages
    }

    static func onlyOpenAIIsAskedForStreamUsage() {
        func options(_ provider: AIProviderKind) -> [String: Bool]? {
            let body = AIRequestBody.make(
                AIRequest(messages: [AIMessage(role: .user, text: "hi")]),
                configuration: AIHTTPConfiguration(
                    provider: provider, baseURL: URL(string: provider.defaultBaseURL)!, model: "m"))
            return body["stream_options"] as? [String: Bool]
        }
        expect(options(.openAI) == ["include_usage": true], "OpenAI is asked to stream its usage")
        expect(options(.openRouter) == nil, "OpenRouter reports usage unasked")
        expect(options(.openAICompatible) == nil, "an unknown server is never sent a field it may refuse")
    }
}

/// A base route that replays one scripted round per request.
final class Rounds: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var rounds: [[AIStreamEvent]]

    init(_ rounds: [[AIStreamEvent]]) {
        self.rounds = rounds
    }

    func stream(_ request: AIRequest) -> AIProviderStream {
        let events: [AIStreamEvent] = lock.withLock { rounds.isEmpty ? [.finished] : rounds.removeFirst() }
        return AIProviderStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
