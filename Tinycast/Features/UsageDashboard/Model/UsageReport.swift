import Foundation

/// What some replies reported, summed as stored: no price table, no estimate.
struct UsageTotals: Equatable, Sendable {
    var replies = 0
    var input = 0
    var output = 0
    var cached = 0
    var reasoning = 0
    /// Nil until some reply reported a cost, so "no cost reported" never reads as free.
    var cost: Double?
    var pricedReplies = 0

    /// Anthropic and Claude's CLI count cached prompt tokens outside `input`, as `AIUsage` does.
    var promptTokens: Int { input + cached }
    var tokens: Int { promptTokens + output }

    mutating func add(_ other: UsageTotals) {
        replies += other.replies
        input += other.input
        output += other.output
        cached += other.cached
        reasoning += other.reasoning
        if let spent = other.cost { cost = (cost ?? 0) + spent }
        pricedReplies += other.pricedReplies
    }
}

/// One conversation's replies inside one slice of a period, as the aggregate query returns them.
struct UsageRow: Equatable, Sendable {
    let conversationID: UUID
    /// `conversation_details.model` as stored: `JSONEncoder` output, keys in no fixed order.
    let modelJSON: String?
    let totals: UsageTotals
    /// Which of the period's slices the replies fell in: an hour of a day, or a day.
    let slice: Int

    init(conversationID: UUID, modelJSON: String?, totals: UsageTotals, slice: Int = 0) {
        self.conversationID = conversationID
        self.modelJSON = modelJSON
        self.totals = totals
        self.slice = slice
    }
}

/// Who a report line is about: an ACP agent by its binding, else the chat's model.
enum UsageSubject: Hashable, Sendable {
    case model(source: AIModelSource, model: String)
    case agent(UUID)
    case unknown

    /// Effort and JSON key order are not part of a model's identity here.
    static func of(modelJSON: String?) -> UsageSubject {
        guard let modelJSON,
            let selection = try? JSONDecoder().decode(
                AIModelSelection.self, from: Data(modelJSON.utf8))
        else { return .unknown }
        return .model(source: selection.source, model: selection.model)
    }

    /// Breaks ties between equal lines, so the order never shuffles from one load to the next.
    var sortKey: String {
        switch self {
        case .model(let source, let model): "0 \(source.storageKey) \(model)"
        case .agent(let id): "1 \(id.uuidString)"
        case .unknown: "2"
        }
    }
}

struct UsageReport: Equatable, Sendable {
    struct Line: Identifiable, Equatable, Sendable {
        let subject: UsageSubject
        let totals: UsageTotals
        var id: UsageSubject { subject }
    }

    /// One bar of the trend: what replies reported from `start` until the next slice begins.
    struct Slice: Identifiable, Equatable, Sendable {
        let start: Date
        var totals = UsageTotals()
        var id: Date { start }
    }

    let lines: [Line]
    let total: UsageTotals
    let slices: [Slice]

    /// `agents` maps a chat to its ACP agent, whose CLI ran it whatever the model picker held.
    init(
        rows: [UsageRow], ledger: [UsageLedgerEntry] = [], slices starts: [Date] = [],
        agents: [UUID: UUID] = [:]
    ) {
        var sums: [UsageSubject: UsageTotals] = [:]
        var trend = starts.map { Slice(start: $0) }
        var decoded: [String: UsageSubject] = [:]
        for row in rows {
            let subject: UsageSubject
            if let agent = agents[row.conversationID] {
                subject = .agent(agent)
            } else if let json = row.modelJSON {
                subject = decoded[json] ?? .of(modelJSON: json)
                decoded[json] = subject
            } else {
                subject = .unknown
            }
            sums[subject, default: UsageTotals()].add(row.totals)
            if trend.indices.contains(row.slice) { trend[row.slice].totals.add(row.totals) }
        }
        for entry in ledger {
            let totals = entry.totals
            sums[entry.subject, default: UsageTotals()].add(totals)
            if let index = starts.lastIndex(where: { $0 <= entry.at }) { trend[index].totals.add(totals) }
        }
        lines = sums.map { Line(subject: $0.key, totals: $0.value) }.sorted(by: Self.precedes)
        total = lines.reduce(into: UsageTotals()) { $0.add($1.totals) }
        slices = trend
    }

    /// Dearest first and every priced line before an unpriced one, then by tokens.
    private static func precedes(_ left: Line, _ right: Line) -> Bool {
        switch (left.totals.cost, right.totals.cost) {
        case (let leftCost?, let rightCost?) where leftCost != rightCost: return leftCost > rightCost
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if left.totals.tokens != right.totals.tokens { return left.totals.tokens > right.totals.tokens }
        return left.subject.sortKey < right.subject.sortKey
    }
}

enum UsageFormat {
    /// Under a dollar, two significant digits, so a fraction of a cent never reads as zero.
    static func cost(_ amount: Double, locale: Locale = .current) -> String {
        let currency = FloatingPointFormatStyle<Double>.Currency(code: "USD", locale: locale)
        guard amount != 0, abs(amount) < 1 else {
            return amount.formatted(currency.precision(.fractionLength(2)))
        }
        return amount.formatted(currency.precision(.significantDigits(2)))
    }

    static func tokens(_ count: Int, locale: Locale = .current) -> String {
        count.formatted(.number.notation(.compactName).locale(locale))
    }
}
