import Foundation

/// Splits chunks into lines of at most `cap` bytes; a longer line is skipped, never held whole.
struct JSONLineSplitter: Sendable {
    let cap: Int
    /// The longest line ever carried across chunks, which the harness pins under `cap`.
    private(set) var largestCarry = 0
    private var carry = Data()
    private var skipping = false

    init(cap: Int) {
        self.cap = cap
    }

    /// The next whole line from `start`, which moves past it; a reader stops once it has enough.
    mutating func next(in chunk: Data, from start: inout Data.Index) -> Data? {
        while start < chunk.endIndex {
            guard let newline = chunk[start...].firstIndex(of: 0x0A) else {
                hold(chunk[start...])
                start = chunk.endIndex
                return nil
            }
            defer {
                start = newline + 1
                skipping = false
            }
            if skipping || carry.count + (newline - start) > cap {
                carry.removeAll(keepingCapacity: true)
                continue
            }
            // A line inside one chunk is handed out as a slice of it, never copied.
            guard !carry.isEmpty else { return chunk[start..<newline] }
            carry.append(chunk[start..<newline])
            largestCarry = max(largestCarry, carry.count)
            let line = carry
            carry = Data()
            return line
        }
        return nil
    }

    /// The last line when the input ends without a newline, unless it ran past `cap`.
    mutating func finish() -> Data? {
        defer {
            carry = Data()
            skipping = false
        }
        return skipping || carry.isEmpty ? nil : carry
    }

    private mutating func hold(_ part: Data) {
        guard !skipping else { return }
        guard carry.count + part.count <= cap else {
            carry.removeAll(keepingCapacity: false)
            skipping = true
            return
        }
        carry.append(part)
        largestCarry = max(largestCarry, carry.count)
    }
}
