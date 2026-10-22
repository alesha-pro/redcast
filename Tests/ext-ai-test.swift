import Foundation
import Synchronization

/// A provider that plays a script: events, pauses, a failure, or a wait that only a cancel ends.
final class ScriptedProvider: AIProvider {
    enum Step: Sendable {
        case event(AIStreamEvent)
        case pause(milliseconds: Int)
        case fail(String)
        case hang
    }

    let steps: [Step]
    let terminated = Mutex(false)

    init(_ steps: [Step]) {
        self.steps = steps
    }

    var wasTerminated: Bool { terminated.withLock { $0 } }

    func stream(_ request: AIRequest) -> AIProviderStream {
        AsyncThrowingStream { continuation in
            let task = Task { [steps] in
                for step in steps {
                    switch step {
                    case .event(let event):
                        continuation.yield(event)
                    case .pause(let milliseconds):
                        try? await Task.sleep(for: .milliseconds(milliseconds))
                    case .fail(let message):
                        continuation.finish(throwing: AIProviderError.responseFailed(message))
                        return
                    case .hang:
                        try? await Task.sleep(for: .seconds(60))
                    }
                    if Task.isCancelled { return }
                }
                continuation.finish()
            }
            continuation.onTermination = { [self] _ in
                terminated.withLock { $0 = true }
                task.cancel()
            }
        }
    }
}

final class Owner {}

@main
@MainActor
struct ExtensionAITests {
    static var failures = 0
    static var passes = 0
    /// Kept alive: a freed owner's address, and so its identifier, can come back for the next one.
    static let owners = (Owner(), Owner())
    static let owner = ObjectIdentifier(owners.0)
    static let otherOwner = ObjectIdentifier(owners.1)

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() async {
        gatesApplyInOrder()
        promptsAreBounded()
        theRequestIsThePromptAlone()
        onlyADeletedConnectionDangles()
        refusalsExplainThemselves()
        theRateLimitSlides()
        await deltasCoalesceUntilRead()
        await aReadWaitsForTheNextDelta()
        await onlyAnswerTextReachesAReader()
        await textBeforeAFailureArrivesFirst()
        await cancellingEndsTheProvider()
        await streamsBelongToTheirOwner()
        await aCancelledReaderCancelsTheStream()
        settingsRoundTrip()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Policy

    static func gatesApplyInOrder() {
        func access(
            _ featureOn: Bool, _ aiOn: Bool, _ launchType: ExtensionLaunchType, _ grant: Bool?
        ) -> ExtensionAIAccess {
            ExtensionAIPolicy.access(featureOn: featureOn, aiOn: aiOn, launchType: launchType, grant: grant)
        }
        expect(access(false, true, .userInitiated, true) == .refused(.featureOff), "the switch comes first")
        expect(access(false, false, .background, false) == .refused(.featureOff), "the switch beats every gate")
        expect(access(true, false, .userInitiated, true) == .refused(.aiOff), "AI off is refused next")
        expect(access(true, false, .background, true) == .refused(.aiOff), "AI off beats background")
        expect(access(true, true, .background, true) == .refused(.background), "background beats an allowance")
        expect(access(true, true, .background, nil) == .refused(.background), "background never asks")
        expect(access(true, true, .userInitiated, false) == .refused(.denied), "a refusal is kept")
        expect(access(true, true, .userInitiated, nil) == .ask, "a first use asks")
        expect(access(true, true, .userInitiated, true) == .allowed, "an allowance is kept")
    }

    static func promptsAreBounded() {
        func refusal(_ raw: String) -> ExtensionAIRefusal? {
            do {
                _ = try ExtensionAIPolicy.prompt(from: raw)
                return nil
            } catch {
                return error
            }
        }
        expect(refusal("") == .emptyPrompt, "an empty prompt is refused")
        expect(refusal(" \n\t ") == .emptyPrompt, "a whitespace prompt is refused")
        let limit = ExtensionAIPolicy.maxPromptBytes
        expect(limit == 262_144, "the cap is 256 KB")
        expect(refusal(String(repeating: "a", count: limit)) == nil, "a prompt at the cap is accepted")
        expect(
            refusal(String(repeating: "a", count: limit + 1)) == .promptTooLong(kilobytes: 257),
            "one byte over is refused, rounded up to whole kilobytes")
        expect(refusal(String(repeating: "€", count: limit / 3)) == nil, "3-byte characters up to the cap pass")
        expect(
            refusal(String(repeating: "€", count: limit / 3 + 1)) == .promptTooLong(kilobytes: 257),
            "the cap counts UTF-8 bytes, not characters")
        expect((try? ExtensionAIPolicy.prompt(from: " hi ")) == " hi ", "an accepted prompt is unchanged")
    }

    static func theRequestIsThePromptAlone() {
        let request = ExtensionAIPolicy.request(prompt: "Name three colours.")
        expect(request.instructions == nil, "no preamble or system prompt")
        expect(
            request.messages.count == 1 && request.messages.first?.role == .user
                && request.messages.first?.text == "Name three colours.",
            "one user message, the prompt")
        expect(request.maxOutputTokens == 4_096, "chat's output limit")
        expect(request.tools.isEmpty && !request.webSearch, "no tools and no web search")
        expect(request.conversationID == nil, "no conversation")
    }

    static func onlyADeletedConnectionDangles() {
        let connection = AIConnection(provider: .openAI, models: ["gpt"])
        let connections = [connection]
        expect(
            ExtensionAIPolicy.isDangling(
                .api(connection: UUID(), model: "gpt", effort: nil), connections: connections),
            "a deleted connection dangles")
        expect(
            ExtensionAIPolicy.isDangling(
                .api(connection: connection.id, model: "gone", effort: nil), connections: connections),
            "a deleted model dangles")
        expect(
            !ExtensionAIPolicy.isDangling(
                .api(connection: connection.id, model: "gpt", effort: "high"), connections: connections),
            "a present connection and model do not")
        expect(!ExtensionAIPolicy.isDangling(.appleIntelligence, connections: []), "on-device never dangles")
        expect(
            !ExtensionAIPolicy.isDangling(.claude(model: "opus", effort: nil), connections: []),
            "an installed route is reported by the factory, never rerouted")
    }

    static func refusalsExplainThemselves() {
        let all: [ExtensionAIRefusal] = [
            .featureOff, .aiOff, .background, .denied, .noModel, .emptyPrompt,
            .promptTooLong(kilobytes: 300), .rateLimited(seconds: 42)
        ]
        let messages = all.compactMap(\.errorDescription)
        expect(messages.count == all.count && messages.allSatisfy { !$0.isEmpty }, "every refusal has a message")
        expect(Set(messages).count == all.count, "no two refusals read alike")
        expect(
            ExtensionAIRefusal.promptTooLong(kilobytes: 300).errorDescription?.contains("300") == true
                && ExtensionAIRefusal.promptTooLong(kilobytes: 300).errorDescription?.contains("256") == true,
            "the size refusal names the size and the cap")
        expect(
            ExtensionAIRefusal.rateLimited(seconds: 42).errorDescription?.contains("42") == true,
            "the rate refusal names the wait")
    }

    // MARK: - Rate limit

    static func theRateLimitSlides() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var limit = ExtensionAIRateLimit()
        for second in 0..<10 {
            expect(limit.admit("a", at: start + Double(second)) == nil, "request \(second + 1) is admitted")
        }
        let wait = limit.admit("a", at: start + 10)
        expect(wait.map { abs($0 - 50) < 0.001 } == true, "the 11th waits until the first leaves the minute")
        expect(limit.admit("b", at: start + 10) == nil, "another extension has its own window")
        expect(limit.admit("a", at: start + 60) == nil, "a minute after the first, one more is admitted")

        var hourly = ExtensionAIRateLimit()
        for index in 0..<100 {
            _ = hourly.admit("a", at: start + Double(index) * 30)
        }
        let refused = hourly.admit("a", at: start + 3_000)
        expect(refused.map { abs($0 - 600) < 0.001 } == true, "the 101st in an hour is refused even spread out")
        expect(hourly.admit("a", at: start + 3_600) == nil, "stamps an hour old are pruned")
    }

    // MARK: - Bridge

    static func settle(_ milliseconds: Int = 40) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    static func read(
        _ bridge: ExtensionAIBridge, _ id: Int, owner: ObjectIdentifier
    ) async -> Result<String?, any Error> {
        do {
            return .success(try await bridge.read(id, owner: owner))
        } catch {
            return .failure(error)
        }
    }

    static func deltasCoalesceUntilRead() async {
        let bridge = ExtensionAIBridge()
        let id = bridge.start(
            ExtensionAIPolicy.request(prompt: "p"),
            on: ScriptedProvider([.event(.text("Hel")), .event(.text("lo"))]), owner: owner)
        await settle()
        let first = await read(bridge, id, owner: owner)
        let second = await read(bridge, id, owner: owner)
        expect((try? first.get()) == "Hello", "deltas that arrived before a read come as one chunk")
        expect((try? second.get()) == .some(nil), "then the end")
        expect(bridge.isIdle, "an ended answer is released")
    }

    static func aReadWaitsForTheNextDelta() async {
        let bridge = ExtensionAIBridge()
        let id = bridge.start(
            ExtensionAIPolicy.request(prompt: "p"),
            on: ScriptedProvider([.pause(milliseconds: 50), .event(.text("a")), .pause(milliseconds: 30)]),
            owner: owner)
        let first = await read(bridge, id, owner: owner)
        expect((try? first.get()) == "a", "a read waits for the next delta")
        let last = await read(bridge, id, owner: owner)
        expect((try? last.get()) == .some(nil), "and the next waits for the end")
        expect(bridge.isIdle, "nothing is left behind")
    }

    static func onlyAnswerTextReachesAReader() async {
        let bridge = ExtensionAIBridge()
        let provider = ScriptedProvider([
            .event(.thinking), .event(.reasoning("hmm")), .event(.searching("q")),
            .event(.usage(AIUsage(inputTokens: 1, outputTokens: 2))), .event(.text("")),
            .event(.text("answer")), .event(.finished)
        ])
        let id = bridge.start(ExtensionAIPolicy.request(prompt: "p"), on: provider, owner: owner)
        await settle()
        let text = await read(bridge, id, owner: owner)
        let end = await read(bridge, id, owner: owner)
        expect((try? text.get()) == "answer", "reasoning, thinking, search and usage are dropped")
        expect((try? end.get()) == .some(nil), "and the answer ends")
    }

    static func textBeforeAFailureArrivesFirst() async {
        let bridge = ExtensionAIBridge()
        let id = bridge.start(
            ExtensionAIPolicy.request(prompt: "p"),
            on: ScriptedProvider([.event(.text("partial")), .fail("The model went away.")]), owner: owner)
        await settle()
        let text = await read(bridge, id, owner: owner)
        let failure = await read(bridge, id, owner: owner)
        expect((try? text.get()) == "partial", "the unread text comes first")
        if case .failure(let error) = failure {
            expect(error.localizedDescription == "The model went away.", "then the provider's own message")
        } else {
            expect(false, "a failed answer throws on the read after its text")
        }
        expect(bridge.isIdle, "a failed answer is released")
    }

    static func cancellingEndsTheProvider() async {
        let bridge = ExtensionAIBridge()
        let provider = ScriptedProvider([.hang])
        let id = bridge.start(ExtensionAIPolicy.request(prompt: "p"), on: provider, owner: owner)
        let reader = Task { await read(bridge, id, owner: owner) }
        await settle()
        bridge.cancel(id)
        let result = await reader.value
        await settle()
        if case .failure(let error) = result {
            expect(error is CancellationError, "a waiting read throws CancellationError")
        } else {
            expect(false, "a cancelled answer does not resolve")
        }
        expect(provider.wasTerminated, "the provider's stream is terminated")
        expect(bridge.isIdle, "the entry is gone")
    }

    static func streamsBelongToTheirOwner() async {
        let bridge = ExtensionAIBridge()
        let first = owner
        let second = otherOwner
        let mine = ScriptedProvider([.hang])
        let theirs = ScriptedProvider([.hang])
        let id = bridge.start(ExtensionAIPolicy.request(prompt: "p"), on: mine, owner: first)
        let other = bridge.start(ExtensionAIPolicy.request(prompt: "p"), on: theirs, owner: second)

        if case .failure(let error) = await read(bridge, id, owner: second) {
            expect(error is ExtensionAIBridge.BridgeError, "another owner's read is refused")
        } else {
            expect(false, "another owner's read is refused")
        }
        if case .failure = await read(bridge, 999, owner: first) {
            expect(true, "an unknown answer is refused")
        } else {
            expect(false, "an unknown answer is refused")
        }
        let waiting = Task { await read(bridge, id, owner: first) }
        await settle()
        if case .failure = await read(bridge, id, owner: first) {
            expect(true, "a second concurrent read is refused")
        } else {
            expect(false, "a second concurrent read is refused")
        }
        bridge.cancel(id, owner: second)
        expect(!bridge.isIdle, "another owner's cancel reaches nothing")

        bridge.cancelAll(owner: first)
        _ = await waiting.value
        await settle()
        expect(mine.wasTerminated && !theirs.wasTerminated, "cancelAll(owner:) touches only that owner")
        bridge.cancelAll()
        await settle()
        expect(theirs.wasTerminated && bridge.isIdle, "cancelAll() ends every answer")
        _ = other
    }

    static func aCancelledReaderCancelsTheStream() async {
        let bridge = ExtensionAIBridge()
        let provider = ScriptedProvider([.hang])
        let id = bridge.start(ExtensionAIPolicy.request(prompt: "p"), on: provider, owner: owner)
        let reader = Task { await read(bridge, id, owner: owner) }
        await settle()
        reader.cancel()
        let result = await reader.value
        await settle()
        if case .failure(let error) = result {
            expect(error is CancellationError, "the cancelled read throws CancellationError")
        } else {
            expect(false, "the cancelled read throws")
        }
        expect(provider.wasTerminated && bridge.isIdle, "cancelling the reading task ends the stream")
    }

    // MARK: - Settings

    static func settingsRoundTrip() {
        let suite = "ext-ai-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            expect(false, "a scratch defaults suite opens")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExtensionAISettingsStore(defaults: defaults)
        expect(!store.isEnabled && store.model == nil && store.grants.isEmpty, "everything starts off")

        store.isEnabled = true
        store.select(.claude(model: "sonnet", effort: "high"))
        store.setGrant(true, for: "color-picker")
        store.setGrant(false, for: "lorem")
        let reloaded = ExtensionAISettingsStore(defaults: defaults)
        expect(reloaded.isEnabled, "the switch persists")
        expect(reloaded.model == .claude(model: "sonnet", effort: "high"), "the model persists")
        expect(reloaded.grants == ["color-picker": true, "lorem": false], "both answers persist")

        store.setGrant(nil, for: "color-picker")
        expect(store.grants == ["lorem": false], "clearing an answer asks again")
        store.setGrant(true, for: "a")
        store.forget(["lorem"])
        expect(store.grants == ["a": true], "forget drops the named extensions")
        store.forgetAll()
        let grantsKey = AppSettingsKey.extensionsAIGrants.rawValue
        expect(store.grants.isEmpty && defaults.object(forKey: grantsKey) == nil, "no answers, no key")
        store.select(nil)
        expect(
            defaults.object(forKey: AppSettingsKey.extensionsAIModel.rawValue) == nil,
            "following AI Chat stores nothing")
        expect(ExtensionAISettingsStore(defaults: defaults).model == nil, "and reloads as following")
    }
}
