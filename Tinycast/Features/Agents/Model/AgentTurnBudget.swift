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

    private(set) var spent = 0
    private(set) var carried = 0

    mutating func carry(_ text: String, calls: [AIToolCall]) {
        carried += text.utf8.count + calls.reduce(0) { $0 + $1.arguments.utf8.count }
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
        guard spent < Self.turnResultBytes else {
            return .failure(result.callID, "This turn's tool output budget is used up.")
        }
        let allowance = min(Self.resultBytes, Self.turnResultBytes - spent)
        let size = result.content.utf8.count
        spent += min(size, allowance)
        guard size > allowance else { return result }
        let content = Self.prefix(result.content, bytes: allowance) + "\n…truncated."
        return AIToolResult(callID: result.callID, content: content, isError: result.isError)
    }

    /// Stubs this turn's oldest results before `keepFrom`; returns the bytes it saved.
    static func elide(_ messages: inout [AIMessage], turnStart: Int, keepFrom: Int) -> Int {
        let results = messages.indices.dropFirst(turnStart).filter { messages[$0].toolResult != nil }
        var total = results.reduce(0) { $0 + (messages[$1].toolResult?.content.utf8.count ?? 0) }
        guard total > elideAbove else { return 0 }
        let names = Dictionary(
            messages[turnStart...].flatMap(\.toolCalls).map { ($0.id, $0.name) }, uniquingKeysWith: { $1 })
        var saved = 0
        for index in results where index < keepFrom && total >= elideTo {
            guard let result = messages[index].toolResult else { continue }
            let name = names[result.callID] ?? "tool"
            let size = result.content.utf8.count
            let replacement = stub(name, bytes: size)
            guard replacement.utf8.count < size, !result.content.hasPrefix(stub(name, bytes: nil)) else {
                continue
            }
            let elided = AIToolResult(callID: result.callID, content: replacement, isError: result.isError)
            messages[index] = AIMessage(role: .tool, text: messages[index].text, toolResult: elided)
            total -= size - replacement.utf8.count
            saved += size - replacement.utf8.count
        }
        return saved
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
