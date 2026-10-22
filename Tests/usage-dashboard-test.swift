import Foundation
import SQLite3

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
        await theQuerySumsRepliesWithUsageInsideThePeriod()
        await theQueryNeverCreatesTheDatabase()
        await theQueryReadsBesideTheWriterAndAfterItCloses()
        await modelsMergeWhateverTheirKeyOrderAndEffort()
        await acpRepliesCountWhatTheirSessionTotalRose()
        linesSortByCostThenTokens()
        periodsFollowTheCalendar()
        periodTitlesNameTheRecentOnes()
        formatsAreCompactAndKeepSmallCosts()
        openRouterKeyStatusDecodes()
        openRouterRequestsAndStatuses()
        await aToolLoopTurnCostsEveryRound()
        onlyOpenAIsOwnAPIIsAskedForStreamUsage()
        periodsSliceIntoHoursAndDays()
        await theTrendSumsEachSliceOfThePeriod()
        ledgerLinesRoundTrip()
        ledgerFilesAppendReadAndTrim()
        await ledgerEntriesJoinTheirModelsLine()
        await theRecorderPassesRepliesThroughAndLogsOnce()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Query

    private static let periodStart = Date(timeIntervalSince1970: 1_790_000_000)
    private static let period = DateInterval(start: periodStart, duration: 86_400)
    private static let connection = UUID()

    private static func scratch(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "usage-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func reply(
        at offset: TimeInterval, _ usage: AIUsage?, toolScope: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            role: .assistant, text: "answer", sentAt: periodStart.addingTimeInterval(offset),
            usage: usage, toolScope: toolScope)
    }

    private static func question(at offset: TimeInterval, toolScope: String? = nil) -> ChatMessage {
        ChatMessage(
            role: .user, text: "question", sentAt: periodStart.addingTimeInterval(offset),
            toolScope: toolScope)
    }

    private static func session(
        _ messages: [ChatMessage], model: AIModelSelection?
    ) -> ChatSession {
        var session = ChatSession(createdAt: periodStart, model: model)
        for message in messages { session.append(message) }
        return session
    }

    static func theQuerySumsRepliesWithUsageInsideThePeriod() async {
        let directory = scratch("sums")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatHistoryStore(directory: directory)
        let priced = session(
            [
                question(at: 10, toolScope: "github"),
                reply(
                    at: 11,
                    AIUsage(
                        inputTokens: 100, outputTokens: 20, cachedInputTokens: 5, reasoningTokens: 3,
                        costUSD: 0.01)),
                question(at: 20),
                reply(at: 21, AIUsage(inputTokens: 200, outputTokens: 40)),
                question(at: 30),
                reply(at: 31, nil),
                reply(at: 32, AIUsage(contextWindow: 200_000))
            ],
            model: .api(connection: connection, model: "deepseek/v4", effort: "high"))
        let edges = session(
            [
                question(at: -5),
                reply(at: -1, AIUsage(inputTokens: 7, outputTokens: 7, costUSD: 1)),
                reply(at: 0, AIUsage(inputTokens: 1, outputTokens: 2, costUSD: 0)),
                reply(at: 86_399, AIUsage(inputTokens: 3, outputTokens: 4)),
                reply(at: 86_400, AIUsage(inputTokens: 9, outputTokens: 9, costUSD: 9))
            ],
            model: .claude(model: "sonnet", effort: nil))
        store.save(priced)
        store.save(edges)

        let rows: [UsageRow]
        do {
            rows = try UsageQuery.rows(databaseURL: store.databaseURL, in: period)
        } catch {
            expect(false, "the query reads a real history: \(error)")
            return
        }
        expect(rows.count == 2, "one row per conversation active in the period")
        let first = rows.first { $0.conversationID == priced.id }?.totals
        expect(first?.replies == 2, "only assistant replies that reported tokens or cost count")
        expect(
            first?.input == 300 && first?.output == 60 && first?.cached == 5 && first?.reasoning == 3,
            "token columns sum per conversation")
        expect(first?.cost == 0.01 && first?.pricedReplies == 1, "a reply without cost adds none")
        expect(first?.promptTokens == 305, "prompt tokens count the cached ones Anthropic keeps apart")
        let second = rows.first { $0.conversationID == edges.id }?.totals
        expect(second?.replies == 2, "the period's start is in and its end is out")
        expect(second?.input == 4 && second?.output == 6, "a reply on either side of it is not summed")
        expect(second?.cost == 0 && second?.pricedReplies == 1, "a cost of zero is still a reported cost")
        let stored = rows.first { $0.conversationID == priced.id }?.modelJSON
        expect(
            UsageSubject.of(modelJSON: stored) == .model(source: .api(connection), model: "deepseek/v4"),
            "the row carries the conversation's model as stored")

        let unpriced = session(
            [question(at: 40), reply(at: 41, AIUsage(inputTokens: 1, outputTokens: 1))], model: nil)
        store.save(unpriced)
        let again = (try? UsageQuery.rows(databaseURL: store.databaseURL, in: period)) ?? []
        let third = again.first { $0.conversationID == unpriced.id }
        expect(third?.totals.cost == nil, "a conversation with no priced reply has no cost, not zero")
        expect(third?.modelJSON == nil, "a chat that never picked a model has none to report")

        let report = try? await UsageQuery.report(
            databaseURL: store.databaseURL, in: period, agents: [:])
        expect(report?.total.replies == 5, "the report off-main sums the same rows")
    }

    static func theQueryNeverCreatesTheDatabase() async {
        let directory = scratch("absent")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "ai-chats.sqlite3")
        let rows = try? UsageQuery.rows(databaseURL: url, in: period)
        expect(rows == [], "a Mac that never chatted has no usage")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["?"]
        expect(left.isEmpty, "and reading it creates nothing")
    }

    static func theQueryReadsBesideTheWriterAndAfterItCloses() async {
        let directory = scratch("wal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatHistoryStore(directory: directory)
        store.save(session([question(at: 1), reply(at: 2, AIUsage(outputTokens: 5))], model: nil))
        let beside = try? UsageQuery.rows(databaseURL: store.databaseURL, in: period)
        expect(beside?.first?.totals.output == 5, "a reader works beside the store's open writer")
        store.save(session([question(at: 3), reply(at: 4, AIUsage(outputTokens: 6))], model: nil))
        let fresh = try? UsageQuery.rows(databaseURL: store.databaseURL, in: period)
        expect(fresh?.count == 2, "and sees what the writer committed since")
        store.close()
        let closed = try? UsageQuery.rows(databaseURL: store.databaseURL, in: period)
        expect(closed?.count == 2, "a history whose writer closed still reads")
    }

    // MARK: - Report

    static func modelsMergeWhateverTheirKeyOrderAndEffort() async {
        let directory = scratch("merge")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatHistoryStore(directory: directory)
        let high = session(
            [question(at: 1), reply(at: 2, AIUsage(inputTokens: 10, outputTokens: 1, costUSD: 0.5))],
            model: .api(connection: connection, model: "m", effort: "high"))
        let reordered = session(
            [question(at: 3), reply(at: 4, AIUsage(inputTokens: 20, outputTokens: 2, costUSD: 0.25))],
            model: .api(connection: connection, model: "m", effort: nil))
        let agentChat = session(
            [question(at: 5), reply(at: 6, AIUsage(inputTokens: 30, outputTokens: 3))],
            model: .api(connection: connection, model: "m", effort: nil))
        let unknown = session(
            [question(at: 7), reply(at: 8, AIUsage(inputTokens: 40, outputTokens: 4))], model: nil)
        for chat in [high, reordered, agentChat, unknown] { store.save(chat) }

        let json = #"{"api":{"model":"m","connection":"\#(connection.uuidString)"}}"#
        var database: OpaquePointer?
        sqlite3_open(store.databaseURL.path, &database)
        let update = """
            UPDATE conversation_details SET model = '\(json)'
            WHERE conversation_id = '\(reordered.id.uuidString)';
            """
        expect(sqlite3_exec(database, update, nil, nil, nil) == SQLITE_OK, "the fixture row is rewritten")
        sqlite3_close(database)

        let agent = UUID()
        guard
            let report = try? await UsageQuery.report(
                databaseURL: store.databaseURL, in: period, agents: [agentChat.id: agent])
        else {
            expect(false, "the merge fixture reads")
            return
        }
        let model = report.lines.first { $0.subject == .model(source: .api(connection), model: "m") }
        expect(model?.totals.replies == 2, "key order and effort never split a model into two lines")
        expect(model?.totals.cost == 0.75, "and its costs add up")
        expect(
            report.lines.contains { $0.subject == .agent(agent) && $0.totals.input == 30 },
            "a chat an ACP agent ran is the agent's, whatever the picker held")
        expect(
            report.lines.contains { $0.subject == .unknown && $0.totals.input == 40 },
            "a chat with no model reads as unknown")
        expect(report.lines.count == 3, "three subjects, three lines")
        expect(report.lines.first?.subject == model?.subject, "the priced line leads")
        var summed = UsageTotals()
        for line in report.lines { summed.add(line.totals) }
        expect(report.total == summed, "the total is the sum of its lines")
        expect(report.total.cost == 0.75 && report.total.pricedReplies == 2, "and keeps what was priced")
    }

    static func acpRepliesCountWhatTheirSessionTotalRose() async {
        let directory = scratch("running")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatHistoryStore(directory: directory)
        func turns(_ costs: [(TimeInterval, Double?)]) -> ChatSession {
            let messages = costs.flatMap { offset, cost in
                [question(at: offset - 1), reply(at: offset, AIUsage(inputTokens: 1, costUSD: cost))]
            }
            return session(messages, model: .claude(model: "sonnet", effort: nil))
        }
        let rising = turns([(10, 0.1), (20, 0.3), (30, 0.6)])
        let straddling = turns([(-20, 0.1), (-10, 0.3), (10, 0.6), (86_410, 1)])
        let relaunched = turns([(10, 0.1), (20, 0.3), (30, 0.05), (40, 0.15)])
        let gapped = turns([(10, 0.1), (20, nil), (30, 0.3)])
        let plain = turns([(10, 0.1), (20, 0.3), (30, 0.6)])
        for chat in [rising, straddling, relaunched, gapped, plain] { store.save(chat) }

        let running: Set = [rising.id, straddling.id, relaunched.id, gapped.id]
        guard
            let rows = try? UsageQuery.rows(
                databaseURL: store.databaseURL, in: period, runningCostChats: running)
        else {
            expect(false, "the running-total fixture reads")
            return
        }
        func cost(_ chat: ChatSession) -> Double? {
            rows.first { $0.conversationID == chat.id }?.totals.cost
        }
        func near(_ value: Double?, _ expected: Double) -> Bool {
            value.map { abs($0 - expected) < 1e-9 } ?? false
        }
        expect(near(cost(rising), 0.6), "running totals of 0.1, 0.3 and 0.6 cost 0.6, not 1.0")
        expect(near(cost(straddling), 0.3), "a period counts only the rise inside it")
        expect(near(cost(relaunched), 0.3 + 0.15), "a total that drops starts a new session")
        expect(near(cost(gapped), 0.3), "an unpriced reply leaves the last total standing")
        expect(near(cost(plain), 1.0), "a chat no ACP agent ran sums its replies as stored")
        let gappedRow = rows.first { $0.conversationID == gapped.id }?.totals
        expect(gappedRow?.replies == 3 && gappedRow?.pricedReplies == 2, "and replies still count once")

        let agent = UUID()
        let report = try? await UsageQuery.report(
            databaseURL: store.databaseURL, in: period, agents: [rising.id: agent])
        let line = report?.lines.first { $0.subject == .agent(agent) }
        expect(near(line?.totals.cost, 0.6), "an ACP agent's line counts what its sessions rose")
        expect(near(report?.total.cost, 0.6 + 0.6 + 0.6 + 0.4 + 1.0), "and chats it never ran sum as stored")
    }

    static func linesSortByCostThenTokens() {
        func row(_ model: String, cost: Double?, input: Int) -> UsageRow {
            let json = #"{"codex":{"model":"\#(model)"}}"#
            return UsageRow(
                conversationID: UUID(), modelJSON: json,
                totals: UsageTotals(
                    replies: 1, input: input, cost: cost, pricedReplies: cost == nil ? 0 : 1))
        }
        let report = UsageReport(rows: [
            row("small", cost: nil, input: 10),
            row("cheap", cost: 0.1, input: 1),
            row("big", cost: nil, input: 900),
            row("dear", cost: 2, input: 1),
            row("free", cost: 0, input: 5)
        ])
        let order = report.lines.map {
            if case .model(_, let model) = $0.subject { return model }
            return "?"
        }
        expect(
            order == ["dear", "cheap", "free", "big", "small"],
            "dearest first, a zero cost before no cost, then by tokens")
        let tied = UsageReport(rows: [row("b", cost: nil, input: 1), row("a", cost: nil, input: 1)])
        let tiedAgain = UsageReport(rows: [row("a", cost: nil, input: 1), row("b", cost: nil, input: 1)])
        expect(tied.lines == tiedAgain.lines, "equal lines keep one order whatever the row order")
        expect(UsageReport(rows: []).total == UsageTotals(), "no rows, nothing reported")
        expect(UsageSubject.of(modelJSON: "{not json") == .unknown, "an unreadable model is unknown")
    }

    // MARK: - Periods

    private static let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        berlin.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    static func periodsFollowTheCalendar() {
        let thursday = date(2026, 10, 22, 15)
        let day = UsagePeriod.day.interval(containing: thursday, calendar: berlin)
        expect(day.start == date(2026, 10, 22, 0) && day.duration == 86_400, "a day is local midnight to midnight")
        let spring = UsagePeriod.day.interval(containing: date(2026, 3, 29), calendar: berlin)
        expect(spring.duration == 23 * 3_600, "the day clocks go forward lasts 23 hours")

        let week = UsagePeriod.week.interval(containing: thursday, calendar: berlin)
        expect(week.start == date(2026, 10, 19, 0), "a week starts on the calendar's first weekday")
        expect(week.end == date(2026, 10, 26, 0), "and ends at the next one, DST and all")

        let month = UsagePeriod.month.interval(containing: thursday, calendar: berlin)
        expect(
            month.start == date(2026, 10, 1, 0) && month.end == date(2026, 11, 1, 0),
            "a month is its first day to the next month's")

        let back = UsagePeriod.month.step(date(2026, 1, 15), by: -1, calendar: berlin)
        let december = UsagePeriod.month.interval(containing: back, calendar: berlin)
        expect(december.start == date(2025, 12, 1, 0), "stepping back crosses into last year")
        let weekBack = UsagePeriod.week.step(date(2026, 1, 2), by: -1, calendar: berlin)
        expect(
            UsagePeriod.week.interval(containing: weekBack, calendar: berlin).start
                == date(2025, 12, 22, 0),
            "and so does a week")

        expect(UsagePeriod.day.isCurrent(day, now: thursday), "the period holding now is current")
        expect(!UsagePeriod.day.isCurrent(day, now: day.end), "its end belongs to the next one")
        let yesterday = UsagePeriod.day.interval(
            containing: UsagePeriod.day.step(thursday, by: -1, calendar: berlin), calendar: berlin)
        expect(!UsagePeriod.day.isCurrent(yesterday, now: thursday), "an earlier period is not")
    }

    static func periodTitlesNameTheRecentOnes() {
        let now = date(2026, 10, 22, 15)
        let locale = Locale(identifier: "en_US")
        func title(_ period: UsagePeriod, stepping count: Int) -> String {
            let anchor = period.step(now, by: count, calendar: berlin)
            return period.title(
                of: period.interval(containing: anchor, calendar: berlin), now: now,
                calendar: berlin, locale: locale)
        }
        expect(title(.day, stepping: 0) == "Today", "today is named")
        expect(title(.day, stepping: -1) == "Yesterday", "and so is yesterday")
        expect(title(.day, stepping: -2) == "Oct 20, 2026", "an older day shows its date")
        expect(title(.week, stepping: 0) == "This Week", "the current week is named")
        let lastWeek = title(.week, stepping: -1)
        expect(
            lastWeek.contains("Oct 12") && lastWeek.contains("18"),
            "an older week shows its first and last day: \(lastWeek)")
        expect(title(.month, stepping: 0) == "This Month", "the current month is named")
        expect(title(.month, stepping: -1) == "September 2026", "an older month shows its name and year")
    }

    static func formatsAreCompactAndKeepSmallCosts() {
        let locale = Locale(identifier: "en_US")
        expect(UsageFormat.cost(0.0042, locale: locale) == "$0.0042", "a fraction of a cent keeps two digits")
        expect(UsageFormat.cost(12.34, locale: locale) == "$12.34", "dollars keep cents")
        expect(UsageFormat.cost(0.5, locale: locale) == "$0.50", "under a dollar reads as cents")
        expect(UsageFormat.cost(0, locale: locale) == "$0.00", "nothing spent reads as zero dollars")
        expect(UsageFormat.tokens(1_234_567, locale: locale) == "1.2M", "tokens are compact")
        expect(UsageFormat.tokens(812, locale: locale) == "812", "small counts stay whole")
    }

    // MARK: - OpenRouter

    private static let keySample = Data(
        """
        {"data":{"label":"sk-or-v1-0a1...f9e","limit":50,"limit_remaining":40.2,
        "limit_reset":"monthly","include_byok_in_limit":false,"usage":9.8,"usage_daily":0.42,
        "usage_weekly":3.1,"usage_monthly":9.8,"byok_usage":0,"byok_usage_daily":0,
        "byok_usage_weekly":0,"byok_usage_monthly":0,"is_free_tier":false,"is_management_key":false,
        "rate_limit":{"requests":-1,"interval":"10s","note":"deprecated"},
        "effective_budget":{"limit_usd":50,"spend_usd":9.8,"remaining_usd":40.2,
        "reset_interval":"monthly","resets_at":"2026-11-01T00:00:00Z"},"budgets":[]}}
        """.utf8)

    static func openRouterKeyStatusDecodes() {
        let status = try? OpenRouterAccount.decodeKey(keySample)
        expect(status?.limit == 50 && status?.limitRemaining == 40.2, "the key's limit and what is left")
        expect(
            status?.usageDaily == 0.42 && status?.usageWeekly == 3.1 && status?.usageMonthly == 9.8,
            "spend per UTC day, week and month")
        expect(status?.isManagementKey == false, "an inference key says it is not a management key")
        expect(
            status?.effectiveBudget?.limitUSD == 50 && status?.effectiveBudget?.remainingUSD == 40.2,
            "the effective budget keeps its own snake-cased names")

        let unlimited = keyJSON(#""label":"k","limit":null,"limit_remaining":null"#)
        let open = try? OpenRouterAccount.decodeKey(unlimited)
        expect(open != nil && open?.limit == nil && open?.effectiveBudget == nil, "a key without a limit decodes")
        expect(open?.spendingLimit == nil, "and has no spending limit to show")
        expect(
            status?.spendingLimit?.remaining == 40.2 && status?.spendingLimit?.limit == 50,
            "a limited key shows what is left of it")
        let budgeted = keyJSON(
            #""limit":50,"limit_remaining":40,"effective_budget":{"limit_usd":20,"remaining_usd":5}"#)
        let tighter = (try? OpenRouterAccount.decodeKey(budgeted))?.spendingLimit
        expect(tighter?.remaining == 5 && tighter?.limit == 20, "the effective budget binds before the key's limit")
        let halfBudget = keyJSON(
            #""limit":50,"limit_remaining":40,"effective_budget":{"limit_usd":null}"#)
        let fallback = (try? OpenRouterAccount.decodeKey(halfBudget))?.spendingLimit
        expect(fallback?.remaining == 40 && fallback?.limit == 50, "an unlimited budget leaves the key's limit")

        let credits = try? OpenRouterAccount.decodeCredits(
            Data(#"{"data":{"total_credits":50,"total_usage":9.75}}"#.utf8))
        expect(credits?.remaining == 40.25, "credits left are bought minus used")

        let refusal = Data(#"{"error":{"code":401,"message":"No auth credentials found"}}"#.utf8)
        var thrown: OpenRouterAccount.Failure?
        do {
            _ = try OpenRouterAccount.decodeKey(refusal)
        } catch {
            thrown = error
        }
        expect(thrown == .malformed, "an error body is not a key status")
    }

    /// A `/key` body with the four spend figures every answer carries, plus `fields`.
    private static func keyJSON(_ fields: String) -> Data {
        let spend = #""usage":0,"usage_daily":0,"usage_weekly":0,"usage_monthly":0"#
        return Data("{\"data\":{\(spend),\(fields)}}".utf8)
    }

    static func openRouterRequestsAndStatuses() {
        let base = URL(string: "https://openrouter.ai/api/v1")!
        let request = OpenRouterAccount.request("key", baseURL: base, key: "sk-test")
        expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/key", "the key's own endpoint")
        expect(request.httpMethod == "GET", "a read, never a write")
        expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test", "the chat's key")
        expect(request.timeoutInterval == 15, "it gives up after 15 seconds")
        let trailing = OpenRouterAccount.request(
            "credits", baseURL: URL(string: "https://openrouter.ai/api/v1/")!, key: "k")
        expect(trailing.url?.absoluteString == "https://openrouter.ai/api/v1/credits", "a trailing slash is fine")
        let written = OpenRouterAccount.request(
            "key", baseURL: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, key: "k")
        expect(
            written.url?.absoluteString == "https://openrouter.ai/api/v1/key",
            "a base written down to the chat endpoint still finds the account")
        expect(OpenRouterAccount.failure(forStatus: 401) == .rejectedKey, "401 is the key")
        expect(OpenRouterAccount.failure(forStatus: 403) == .rejectedKey, "and so is 403")
        expect(OpenRouterAccount.failure(forStatus: 502) == .unavailable, "a 5xx is OpenRouter's")
        expect(OpenRouterAccount.failure(forStatus: 0) == .unavailable, "and so is no answer")
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

    static func onlyOpenAIsOwnAPIIsAskedForStreamUsage() {
        func options(_ provider: AIProviderKind, at base: String? = nil) -> [String: Bool]? {
            let body = AIRequestBody.make(
                AIRequest(messages: [AIMessage(role: .user, text: "hi")]),
                configuration: AIHTTPConfiguration(
                    provider: provider, baseURL: URL(string: base ?? provider.defaultBaseURL)!,
                    model: "m"))
            return body["stream_options"] as? [String: Bool]
        }
        expect(options(.openAI) == ["include_usage": true], "OpenAI is asked to stream its usage")
        expect(
            options(.openAI, at: "https://gateway.example/v1") == nil,
            "an OpenAI preset pointed at a gateway is never sent a field it may refuse")
        expect(options(.openRouter) == nil, "OpenRouter reports usage unasked")
        expect(
            options(.openAICompatible, at: "https://llm.example/v1") == nil,
            "nor is an unknown server")
        expect(
            options(.openAICompatible) == ["include_usage": true],
            "a compatible preset left on OpenAI's own endpoint is OpenAI")
    }
}

// MARK: - Trend

extension UsageDashboardTests {
    static func periodsSliceIntoHoursAndDays() {
        let thursday = date(2026, 10, 22, 15)
        let day = UsagePeriod.day.interval(containing: thursday, calendar: berlin)
        let hours = UsagePeriod.day.slices(of: day, calendar: berlin)
        expect(hours.count == 24 && hours.first == day.start, "a day is sliced into its hours")
        expect(hours[14] == date(2026, 10, 22, 14), "each slice starts on the hour")
        let spring = UsagePeriod.day.interval(containing: date(2026, 3, 29), calendar: berlin)
        expect(UsagePeriod.day.slices(of: spring, calendar: berlin).count == 23, "a 23-hour day has 23 bars")
        let autumn = UsagePeriod.day.interval(containing: date(2026, 10, 25), calendar: berlin)
        expect(UsagePeriod.day.slices(of: autumn, calendar: berlin).count == 25, "and a 25-hour day 25")

        let week = UsagePeriod.week.interval(containing: thursday, calendar: berlin)
        let days = UsagePeriod.week.slices(of: week, calendar: berlin)
        expect(days.count == 7, "a week is sliced into its days")
        expect(days.last == date(2026, 10, 25, 0), "each at local midnight, across the clock change")
        let october = UsagePeriod.month.interval(containing: thursday, calendar: berlin)
        expect(UsagePeriod.month.slices(of: october, calendar: berlin).count == 31, "October has 31 bars")
        let february = UsagePeriod.month.interval(containing: date(2026, 2, 10), calendar: berlin)
        expect(UsagePeriod.month.slices(of: february, calendar: berlin).count == 28, "February 28")

        let locale = Locale(identifier: "en_US")
        let hour = UsagePeriod.day.sliceTitle(of: hours[14], calendar: berlin, locale: locale)
        expect(hour.hasPrefix("2") && hour.hasSuffix("PM"), "an hour's bar is named by its hour: \(hour)")
        expect(
            UsagePeriod.month.sliceTitle(of: days[2], calendar: berlin, locale: locale) == "Oct 21",
            "a day's bar by its date")
    }

    static func theTrendSumsEachSliceOfThePeriod() async {
        let directory = scratch("trend")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatHistoryStore(directory: directory)
        let early = session(
            [
                question(at: 5), reply(at: 10, AIUsage(inputTokens: 1, outputTokens: 1, costUSD: 0.1)),
                question(at: 3_650), reply(at: 3_700, AIUsage(inputTokens: 2, outputTokens: 2)),
                question(at: 3_750), reply(at: 3_800, AIUsage(inputTokens: 3, outputTokens: 3))
            ],
            model: .api(connection: connection, model: "m", effort: nil))
        let late = session(
            [question(at: 86_000), reply(at: 86_399, AIUsage(inputTokens: 4, outputTokens: 4))],
            model: .codex(model: "c", effort: nil))
        let running = session(
            [
                question(at: 20), reply(at: 30, AIUsage(inputTokens: 1, costUSD: 0.1)),
                question(at: 3_690), reply(at: 3_700, AIUsage(inputTokens: 1, costUSD: 0.3))
            ],
            model: .claude(model: "sonnet", effort: nil))
        for chat in [early, late, running] { store.save(chat) }
        let slices = (0..<24).map { periodStart.addingTimeInterval(TimeInterval($0) * 3_600) }

        let rows = (try? UsageQuery.rows(databaseURL: store.databaseURL, in: period, slices: slices)) ?? []
        let earlyRows = rows.filter { $0.conversationID == early.id }
        expect(earlyRows.count == 2, "a chat active in two slices returns a row for each")
        expect(
            earlyRows.first { $0.slice == 1 }?.totals.replies == 2,
            "the slice is the last one starting at or before the reply")
        expect(rows.first { $0.conversationID == late.id }?.slice == 23, "the period's last second is its last slice")

        let agent = UUID()
        guard
            let report = try? await UsageQuery.report(
                databaseURL: store.databaseURL, in: period, slices: slices, agents: [running.id: agent])
        else {
            expect(false, "the trend fixture reads")
            return
        }
        expect(report.slices.map(\.start) == slices, "one bar per slice, in order")
        expect(
            report.slices[0].totals.replies == 2 && report.slices[1].totals.replies == 3,
            "replies land in their hour")
        expect(report.slices[23].totals.tokens == 8, "and so do their tokens")
        expect(
            abs((report.slices[1].totals.cost ?? 0) - 0.2) < 1e-9,
            "an ACP session's rise is counted in the slice it rose in")
        var summed = UsageTotals()
        for slice in report.slices { summed.add(slice.totals) }
        expect(
            summed.tokens == report.total.tokens && summed.replies == report.total.replies,
            "bars add up to the total")
        let model = report.lines.first { $0.subject == .model(source: .api(connection), model: "m") }
        expect(model?.totals.replies == 3, "slicing never splits a line")
    }
}

// MARK: - Ledger

extension UsageDashboardTests {
    private static let ledgerNow = Date(timeIntervalSince1970: 1_790_100_000)

    private static func entry(
        _ offset: TimeInterval, route: String = "codex", model: String = "gpt", cost: Double? = 0.01
    ) -> UsageLedgerEntry {
        UsageLedgerEntry(
            at: ledgerNow.addingTimeInterval(offset), origin: .quickAction, route: route, model: model,
            usage: AIUsage(inputTokens: 10, outputTokens: 2, costUSD: cost))
    }

    static func ledgerLinesRoundTrip() {
        let full = UsageLedgerEntry(
            at: ledgerNow.addingTimeInterval(0.7), origin: .voice,
            selection: .api(connection: connection, model: "g", effort: "low"),
            usage: AIUsage(
                inputTokens: 100, outputTokens: 20, cachedInputTokens: 5, reasoningTokens: 3, costUSD: 0.000_12))
        let line = full.line
        expect(line.hasSuffix("\n") && line.filter { $0 == "\n" }.count == 1, "one entry is one line")
        expect(line.hasPrefix("1790100000\tvoice\tapi:\(connection.uuidString)\tg\t"), "date first, whole seconds")
        expect(UsageLedgerEntry(line: String(line.dropLast())) == full, "a line reads back as written")
        expect(full.subject == .model(source: .api(connection), model: "g"), "effort is not part of the subject")
        expect(full.totals.promptTokens == 105 && full.totals.pricedReplies == 1, "an entry is one priced reply")

        let bare = UsageLedgerEntry(
            at: ledgerNow, origin: .chatTitle, route: "claude", model: "s\tx\ny", usage: AIUsage())
        let bareLine = bare.line
        expect(bareLine.split(separator: "\t", omittingEmptySubsequences: false).count == 9, "nine fields")
        let read = UsageLedgerEntry(line: String(bareLine.dropLast()))
        expect(read?.model == "s x y", "a tab or newline in a model id cannot break the line")
        expect(read?.usage == AIUsage() && read?.totals.cost == nil, "unreported figures stay unreported")
        expect(read?.subject == .model(source: .claude, model: "s x y"), "an installed tool's route reads back")

        let later = UsageLedgerEntry(line: "1790100000\tmeeting\tcodex\tgpt\t1\t2\t\t\t0.5\tnew\tfields")
        expect(later?.origin == nil && later?.usage.outputTokens == 2, "a later build's origin and fields are ignored")
        expect(later?.usage.costUSD == 0.5, "the cost column still reads")
        let short = UsageLedgerEntry(line: "1790100000\tvoice\tgrok\tm")
        expect(short?.usage == AIUsage(), "missing figures are unreported")
        let unknown = UsageLedgerEntry(line: "1790100000\tvoice\tgemini\tm")
        expect(unknown?.subject == .unknown, "an unknown route is unknown")
        expect(UsageLedgerEntry(line: "1790100000\tvoice\tapi:nope\tm")?.subject == .unknown, "and so is a bad id")
        for garbage in ["", "abc", "1790100000", "1790100000\tvoice\t\tm", "x\tvoice\tcodex\tm"] {
            expect(UsageLedgerEntry(line: garbage) == nil, "an unreadable line is no entry: \(garbage)")
        }
        expect(
            UsageLedgerEntry(line: "1790100000\tvoice\tcodex\tm\t1\t1\t\t\tnan")?.usage.costUSD == nil,
            "a cost that is not a number is not a cost")
    }

    static func ledgerFilesAppendReadAndTrim() {
        let directory = scratch("ledger")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "ai-usage.tsv")
        let all = DateInterval(start: .distantPast, end: .distantFuture)
        expect((try? UsageLedger.entries(at: url, in: all)) == [], "no log is no usage")
        expect(!FileManager.default.fileExists(atPath: url.path), "and reading it creates nothing")

        for offset in [-10.0, -5, 0] { UsageLedger.append(entry(offset * 86_400), to: url) }
        let recent = DateInterval(
            start: ledgerNow.addingTimeInterval(-6 * 86_400), end: ledgerNow.addingTimeInterval(1))
        expect((try? UsageLedger.entries(at: url, in: recent))?.count == 2, "a period reads only its own lines")
        expect((try? UsageLedger.entries(at: url, in: all))?.count == 3, "every append is one line")

        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        try? handle?.write(contentsOf: Data("1790100001\tvoice\tco".utf8))
        try? handle?.close()
        expect((try? UsageLedger.entries(at: url, in: all))?.count == 3, "a line still being written is not read")
        UsageLedger.append(entry(1), to: url)
        let afterCut = (try? UsageLedger.entries(at: url, in: all)) ?? []
        expect(afterCut.count == 4 && afterCut.last == entry(1), "a cut-short line never swallows the next one")

        func write(_ offsetsInDays: [Double], garbage: Bool = false) {
            let lines = offsetsInDays.map { entry($0 * 86_400).line }.joined()
            try? Data(((garbage ? "garbage\n" : "") + lines).utf8).write(to: url)
        }
        write([-500, -450, -420, -10])
        UsageLedger.append(entry(0), to: url)
        let trimmed = ((try? UsageLedger.entries(at: url, in: all)) ?? []).map(\.at)
        expect(
            trimmed == [entry(-10 * 86_400).at, entry(0).at],
            "past 430 days the log is rewritten without what is older than 400")

        write([-420, -10])
        UsageLedger.append(entry(0), to: url)
        expect((try? UsageLedger.entries(at: url, in: all))?.count == 3, "inside the slack nothing is rewritten")

        write([-10], garbage: true)
        UsageLedger.append(entry(0), to: url)
        let cleaned = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        expect(
            !cleaned.contains("garbage") && cleaned.split(separator: "\n").count == 2,
            "an unreadable head is trimmed away")
    }

    static func ledgerEntriesJoinTheirModelsLine() async {
        let directory = scratch("ledger-report")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatHistoryStore(directory: directory)
        store.save(
            session(
                [question(at: 1), reply(at: 2, AIUsage(inputTokens: 10, outputTokens: 1, costUSD: 0.25))],
                model: .api(connection: connection, model: "m", effort: "high")))
        let ledger = directory.appending(path: "ai-usage.tsv")
        let route = AIModelSource.api(connection).storageKey
        let quick = UsageLedgerEntry(
            at: periodStart.addingTimeInterval(7_300), origin: .quickAction, route: route, model: "m",
            usage: AIUsage(inputTokens: 5, outputTokens: 5, costUSD: 0.5))
        let stray = UsageLedgerEntry(
            at: periodStart.addingTimeInterval(90), origin: .extensionAI, route: "gone", model: "x",
            usage: AIUsage(inputTokens: 1))
        let outside = UsageLedgerEntry(
            at: periodStart.addingTimeInterval(-1), origin: .voice, route: route, model: "m",
            usage: AIUsage(inputTokens: 99, costUSD: 9))
        for entry in [quick, stray, outside] { UsageLedger.append(entry, to: ledger) }

        let slices = [periodStart, periodStart.addingTimeInterval(3_600), periodStart.addingTimeInterval(7_200)]
        guard
            let report = try? await UsageQuery.report(
                databaseURL: store.databaseURL, ledgerURL: ledger, in: period, slices: slices, agents: [:])
        else {
            expect(false, "the ledger fixture reads")
            return
        }
        let model = report.lines.first { $0.subject == .model(source: .api(connection), model: "m") }
        expect(model?.totals.replies == 2 && model?.totals.cost == 0.75, "a Quick Action adds to its model's line")
        expect(report.lines.contains { $0.subject == .unknown && $0.totals.input == 1 }, "an unknown route is unknown")
        expect(report.total.replies == 3, "an entry outside the period is left out")
        expect(
            report.slices[2].totals.replies == 1 && report.slices[0].totals.replies == 2,
            "entries land in their slice")

        let noHistory = directory.appending(path: "never.sqlite3")
        let onlyLog = try? await UsageQuery.report(
            databaseURL: noHistory, ledgerURL: ledger, in: period, agents: [:])
        expect(onlyLog?.total.replies == 2, "a Mac that never chatted still counts its Quick Actions")
    }
}

// MARK: - Recording

extension UsageDashboardTests {
    static func theRecorderPassesRepliesThroughAndLogsOnce() async {
        let directory = scratch("recorder")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = directory.appending(path: "ai-usage.tsv")
        let selection = AIModelSelection.api(connection: connection, model: "m", effort: nil)
        let first = AIUsage(inputTokens: 1, outputTokens: 1)
        let last = AIUsage(inputTokens: 7, outputTokens: 3, costUSD: 0.02)
        let script: [AIStreamEvent] = [.text("a"), .usage(first), .thinking, .text("b"), .usage(last), .finished]
        let recorder = UsageRecordingProvider.wrapping(
            Rounds([script]), for: selection, as: .quickAction, ledger: ledger)
        var seen: [AIStreamEvent] = []
        do {
            for try await event in recorder.stream(AIRequest(messages: [])) { seen.append(event) }
        } catch {
            expect(false, "the recorded stream finishes: \(error)")
        }
        expect(seen == script, "every event passes through, unchanged and in order")
        let entries = await logged(at: ledger, count: 1)
        expect(entries.count == 1 && entries.first?.usage == last, "one line, with the last usage reported")
        expect(
            entries.first?.origin == .quickAction && entries.first?.route == selection.source.storageKey,
            "named by its origin and route")

        let silentLedger = directory.appending(path: "silent.tsv")
        let silent = UsageRecordingProvider.wrapping(
            Rounds([[.text("x"), .finished]]), for: selection, as: .voice, ledger: silentLedger)
        await drain(silent)
        try? await Task.sleep(for: .milliseconds(100))
        expect(!FileManager.default.fileExists(atPath: silentLedger.path), "a reply that reported nothing logs nothing")

        let local = UsageRecordingProvider.wrapping(
            Rounds([]), for: .appleIntelligence, as: .quickAction, ledger: ledger)
        expect(local is Rounds, "Apple Intelligence is passed back as it was, so its type still caps it")

        let stoppedLedger = directory.appending(path: "stopped.tsv")
        let stopped = UsageRecordingProvider.wrapping(
            Rounds([[.usage(last), .finished, .text("never read")]]), for: selection, as: .chatTitle,
            ledger: stoppedLedger)
        do {
            for try await event in stopped.stream(AIRequest(messages: [])) {
                if case .finished = event { break }
            }
        } catch {
            expect(false, "the stopped stream reads: \(error)")
        }
        let stoppedEntries = await logged(at: stoppedLedger, count: 1)
        expect(stoppedEntries.count == 1, "a reader that stops early still has it logged")

        let failedLedger = directory.appending(path: "failed.tsv")
        let failing = UsageRecordingProvider.wrapping(
            FailsAfter([.usage(last)]), for: selection, as: .extensionAI, ledger: failedLedger)
        var thrown: Error?
        do {
            for try await _ in failing.stream(AIRequest(messages: [])) {}
        } catch {
            thrown = error
        }
        expect(thrown as? AIProviderError == .malformedResponse, "a failure reaches the reader as it was thrown")
        let failedEntries = await logged(at: failedLedger, count: 1)
        expect(failedEntries.count == 1, "and a reply billed before it failed is logged")
    }

    private static func drain(_ provider: any AIProvider) async {
        do {
            for try await _ in provider.stream(AIRequest(messages: [])) {}
        } catch {
            expect(false, "the scripted stream finishes: \(error)")
        }
    }

    /// The append lands on the stream's own task, after the reader has its last event.
    private static func logged(at url: URL, count: Int) async -> [UsageLedgerEntry] {
        let all = DateInterval(start: .distantPast, end: .distantFuture)
        for _ in 0..<100 {
            if let entries = try? UsageLedger.entries(at: url, in: all), entries.count >= count { return entries }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return (try? UsageLedger.entries(at: url, in: all)) ?? []
    }
}

/// A route that streams some events and then fails, as a dropped connection does.
struct FailsAfter: AIProvider {
    let events: [AIStreamEvent]

    init(_ events: [AIStreamEvent]) {
        self.events = events
    }

    func stream(_ request: AIRequest) -> AIProviderStream {
        AIProviderStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish(throwing: AIProviderError.malformedResponse)
        }
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
