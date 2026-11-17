import Foundation

/// What a turn's tool results may add, so a turn that keeps calling still ends.
struct AgentTurnBudget: Sendable {
    /// Mirrors `AIToolLoopProvider`; agent-loop-test fails the day the two part.
    static let resultBytes = 32_768
    /// Four times upstream's, which stops an agent after about four full `read_file` pages.
    static let turnResultBytes = 524_288
    static let historyBytes = 1_048_576
    /// Past this a turn's results are elided down to `elideTo`; the gap keeps the prefix cacheable.
    static let elideAbove = 160 * 1_024
    static let elideTo = 96 * 1_024
    /// Each round's output cap: a report sent through `write_file` must fit in one reply, thinking too.
    static let outputTokens = 32_768

    /// What the run's results may add in all, from its effort.
    let allowance: Int
    private(set) var spent = 0
    private(set) var carried = 0

    init(allowance: Int = turnResultBytes) {
        self.allowance = allowance
    }

    /// A reply's text, calls and the reasoning that goes back with them: each rides every later round.
    mutating func carry(_ text: String, calls: [AIToolCall], reasoning: AIReasoningReplay? = nil) {
        carried += text.utf8.count + calls.reduce(0) { $0 + $1.arguments.utf8.count }
        carried += reasoning?.bytes ?? 0
    }

    /// Elided bytes no longer travel with every round, so they stop counting toward the wall.
    mutating func release(_ bytes: Int) {
        carried -= bytes
    }

    /// Upstream's cut and wording, so a model meets the same limits on either loop.
    mutating func admit(_ result: AIToolResult) -> AIToolResult {
        let kept = bounded(result)
        carried += kept.content.utf8.count
        return kept
    }

    private mutating func bounded(_ result: AIToolResult) -> AIToolResult {
        guard spent < allowance else {
            return .failure(result.callID, "This turn's tool output budget is used up.")
        }
        let room = min(Self.resultBytes, allowance - spent)
        let size = result.content.utf8.count
        spent += min(size, room)
        guard size > room else { return result }
        let content = Self.prefix(result.content, bytes: room) + "\n…truncated."
        return AIToolResult(callID: result.callID, content: content, isError: result.isError)
    }

    /// Stubs older results and sheds older reasoning of the turn before `keepFrom`; returns the saving.
    static func elide(
        _ messages: inout [AIMessage], turnStart: Int, keepFrom: Int, above: Int = elideAbove,
        to elideTo: Int = elideTo
    ) -> Int {
        let held = messages.indices.dropFirst(turnStart).filter { size(of: messages[$0]) > 0 }
        var total = held.reduce(0) { $0 + size(of: messages[$1]) }
        guard total > above else { return 0 }
        let names = Dictionary(
            messages[turnStart...].flatMap(\.toolCalls).map { ($0.id, $0.name) }, uniquingKeysWith: { $1 })
        var saved = 0
        var edited: Int?
        for index in held where index < keepFrom && total >= elideTo {
            let before = size(of: messages[index])
            if let result = messages[index].toolResult {
                let name = names[result.callID] ?? "tool"
                let replacement = stub(name, bytes: before)
                guard replacement.utf8.count < before, !result.content.hasPrefix(stub(name, bytes: nil))
                else { continue }
                let elided = AIToolResult(
                    callID: result.callID, content: replacement, isError: result.isError)
                messages[index] = AIMessage(role: .tool, text: messages[index].text, toolResult: elided)
                edited = edited ?? index
            } else if let reasoning = messages[index].reasoning {
                messages[index] = replacing(messages[index], reasoning: reasoning.shed)
            }
            let freed = before - size(of: messages[index])
            total -= freed
            saved += freed
        }
        if let edited { unbind(&messages, after: edited) }
        return saved
    }

    /// What elision can shrink in a message of the turn: a result's text, or the reasoning sent back.
    private static func size(of message: AIMessage) -> Int {
        message.toolResult?.content.utf8.count ?? message.reasoning?.bytes ?? 0
    }

    /// Claude's thinking blocks are signed over what came before them, so an edit voids later ones.
    static func unbind(_ messages: inout [AIMessage], after index: Int) {
        for later in messages.indices where later > index {
            guard let reasoning = messages[later].reasoning, reasoning.bindsPrefix else { continue }
            messages[later] = replacing(messages[later], reasoning: reasoning.unbound)
        }
    }

    private static func replacing(_ message: AIMessage, reasoning: AIReasoningReplay) -> AIMessage {
        AIMessage(
            role: message.role, text: message.text, images: message.images, documents: message.documents,
            audio: message.audio, toolCalls: message.toolCalls, toolResult: message.toolResult,
            reasoning: reasoning)
    }

    /// An overflow with nothing left to elide sheds the older half of the history, from a question.
    static func dropHistory(_ messages: inout [AIMessage], turnStart: inout Int, keepFrom: inout Int) -> Bool {
        guard let question = messages[..<turnStart].lastIndex(where: { $0.role == .user }), question > 1
        else { return false }
        var cut = question / 2
        while cut < question, messages[cut].role != .user { cut += 1 }
        guard cut > 0 else { return false }
        messages.removeFirst(cut)
        turnStart -= cut
        keepFrom -= cut
        unbind(&messages, after: -1)
        return true
    }

    /// Without a size, the opening every stub of that tool's results shares.
    private static func stub(_ name: String, bytes: Int?) -> String {
        let opening = "[Earlier \(name) result elided to save room"
        guard let bytes else { return opening }
        return opening + ": \(bytes) bytes. Call it again if you need it.]"
    }

    /// Whole scalars only, where upstream decodes a split one into a replacement character.
    private static func prefix(_ text: String, bytes: Int) -> String {
        var used = 0
        let kept = text.unicodeScalars.prefix { scalar in
            used += scalar.utf8.count
            return used <= bytes
        }
        return String(kept)
    }
}

/// A run's output cap: Claude's from the start, an OpenAI-shaped route's once its own default cut.
struct AgentOutputCap: Equatable, Sendable {
    let tokens: Int
    private(set) var forced = false
    private(set) var refused = false

    init(tokens: Int) {
        self.tokens = tokens
    }

    /// What the next round asks for; nil once a route refused the number.
    var request: AIOutputCap? {
        refused ? nil : AIOutputCap(tokens: tokens, forced: forced)
    }

    /// A reply hit the limit, so every shape is sent the number from now on; true if that is new.
    mutating func raise() -> Bool {
        guard !forced, !refused else { return false }
        forced = true
        return true
    }

    /// A route refused the number, by name or for room: it keeps its own default from now on.
    mutating func refuse() {
        refused = true
    }
}

/// Which calls of a round run together: neighbours that may share a round, `width` at most.
enum AgentBatchPolicy {
    static func batches(_ concurrent: [Bool], width: Int) -> [Range<Int>] {
        var batches: [Range<Int>] = []
        var start = 0
        for index in concurrent.indices.dropFirst() {
            guard !(concurrent[start] && concurrent[index] && index - start < width) else { continue }
            batches.append(start..<index)
            start = index
        }
        if !concurrent.isEmpty { batches.append(start..<concurrent.count) }
        return batches
    }
}
