import Foundation

/// One reply no chat keeps, as the usage log stores it: when, which route and model, what it cost.
struct UsageLedgerEntry: Equatable, Sendable {
    enum Origin: String, Sendable {
        case quickAction = "quick-action"
        case voice
        case extensionAI = "extension"
        case chatTitle = "chat-title"
    }

    let at: Date
    /// Nil for an origin a later build wrote.
    let origin: Origin?
    /// `AIModelSource.storageKey`, so a connection is named by its id and never by its title.
    let route: String
    let model: String
    let usage: AIUsage

    init(at: Date, origin: Origin?, route: String, model: String, usage: AIUsage) {
        self.at = Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded(.down))
        self.origin = origin
        self.route = route
        self.model = model
        self.usage = usage
    }

    init(at: Date, origin: Origin, selection: AIModelSelection, usage: AIUsage) {
        self.init(
            at: at, origin: origin, route: selection.source.storageKey, model: selection.model,
            usage: usage)
    }

    var subject: UsageSubject {
        guard let source = Self.source(route: route) else { return .unknown }
        return .model(source: source, model: model)
    }

    var totals: UsageTotals {
        UsageTotals(
            replies: 1, input: usage.inputTokens ?? 0, output: usage.outputTokens ?? 0,
            cached: usage.cachedInputTokens ?? 0, reasoning: usage.reasoningTokens ?? 0,
            cost: usage.costUSD, pricedReplies: usage.costUSD == nil ? 0 : 1)
    }

    /// The inverse of `storageKey`, so a route names a source the way its settings do.
    private static func source(route: String) -> AIModelSource? {
        let named = [AIModelSource.appleIntelligence] + InstalledAIKind.allCases.map(\.source)
        if let source = named.first(where: { $0.storageKey == route }) { return source }
        guard route.hasPrefix("api:"), let id = UUID(uuidString: String(route.dropFirst(4))) else { return nil }
        return .api(id)
    }

    // MARK: - Line format

    private static let separator: Character = "\t"

    /// Tab-separated with the date first; an empty field is a figure the route did not report.
    var line: String {
        let fields: [String] = [
            String(Int64(at.timeIntervalSince1970)), origin?.rawValue ?? "", Self.field(route),
            Self.field(model), Self.number(usage.inputTokens), Self.number(usage.outputTokens),
            Self.number(usage.cachedInputTokens), Self.number(usage.reasoningTokens),
            usage.costUSD.map { String($0) } ?? ""
        ]
        return fields.joined(separator: String(Self.separator)) + "\n"
    }

    /// Fields past the ninth are a later build's and ignored; missing trailing ones are unreported.
    init?(line: String) {
        let fields = line.split(separator: Self.separator, omittingEmptySubsequences: false)
        guard fields.count >= 4, let seconds = Int64(fields[0]), !fields[2].isEmpty else { return nil }
        func count(_ index: Int) -> Int? { fields.indices.contains(index) ? Int(fields[index]) : nil }
        let cost = fields.indices.contains(8) ? Double(fields[8]) : nil
        self.init(
            at: Date(timeIntervalSince1970: TimeInterval(seconds)),
            origin: Origin(rawValue: String(fields[1])), route: String(fields[2]), model: String(fields[3]),
            usage: AIUsage(
                inputTokens: count(4), outputTokens: count(5), cachedInputTokens: count(6),
                reasoningTokens: count(7), costUSD: cost.flatMap { $0.isFinite ? $0 : nil }))
    }

    private static func field(_ text: String) -> String {
        String(text.map { $0 == "\t" || $0.isNewline ? " " : $0 })
    }

    private static func number(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    // MARK: - The file

    /// The entries inside `interval`; a line is decoded only once its date says it belongs.
    static func entries(in data: Data, during interval: DateInterval) -> [UsageLedgerEntry] {
        var found: [UsageLedgerEntry] = []
        forEachLine(in: data) { line in
            guard let date = date(of: line), interval.start <= date, date < interval.end,
                let text = String(bytes: line, encoding: .utf8), let entry = UsageLedgerEntry(line: text)
            else { return }
            found.append(entry)
        }
        return found
    }

    /// The oldest entry's date, read from the file's first bytes, since lines are only appended.
    static func firstDate(in prefix: Data) -> Date? {
        date(of: prefix[...])
    }

    /// What a trim keeps: every readable line from `cutoff` on, each ending in a newline.
    static func kept(_ data: Data, since cutoff: Date) -> Data {
        var kept = Data()
        forEachLine(in: data) { line in
            guard let date = date(of: line), date >= cutoff,
                let text = String(bytes: line, encoding: .utf8), UsageLedgerEntry(line: text) != nil
            else { return }
            kept.append(contentsOf: line)
            kept.append(UInt8(ascii: "\n"))
        }
        return kept
    }

    /// A last line with no newline is a write still landing, so it is not a line yet.
    private static func forEachLine(in data: Data, _ body: (Data.SubSequence) -> Void) {
        var start = data.startIndex
        while let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
            if end > start { body(data[start..<end]) }
            start = data.index(after: end)
        }
    }

    /// The leading seconds, up to the first tab; anything else there makes the line unreadable.
    private static func date(of line: Data.SubSequence) -> Date? {
        var seconds: Int64 = 0
        var digits = 0
        for byte in line {
            if byte == UInt8(ascii: "\t") {
                return digits == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(seconds))
            }
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte), digits < 12 else { return nil }
            seconds = seconds * 10 + Int64(byte - UInt8(ascii: "0"))
            digits += 1
        }
        return nil
    }
}
