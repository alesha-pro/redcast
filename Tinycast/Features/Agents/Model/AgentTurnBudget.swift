import Foundation

/// What a turn's tool results may add, so a turn that keeps calling still ends.
struct AgentTurnBudget: Sendable {
    /// Mirrors `AIToolLoopProvider`; agent-loop-test fails the day the two part.
    static let resultBytes = 32_768
    static let turnResultBytes = 131_072
    static let historyBytes = 1_048_576

    private(set) var spent = 0
    private(set) var carried = 0

    mutating func carry(_ text: String, calls: [AIToolCall]) {
        carried += text.utf8.count + calls.reduce(0) { $0 + $1.arguments.utf8.count }
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
