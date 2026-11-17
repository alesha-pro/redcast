import Foundation
import SQLite3

private let usageSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One aggregate over chat history per period, on a read-only connection opened for it alone.
enum UsageQuery {
    enum Failure: Error, Equatable {
        case unreadable
    }

    /// Every chat in `agents` is ACP-bound, so its replies store their session's running cost.
    @concurrent
    static func report(
        databaseURL: URL, ledgerURL: URL? = nil, in interval: DateInterval, slices: [Date] = [],
        agents: [UUID: UUID]
    ) async throws -> UsageReport {
        let chats = Set(agents.keys)
        let rows = try rows(
            databaseURL: databaseURL, in: interval, slices: slices, runningCostChats: chats)
        try Task.checkCancellation()
        let ledger = try ledgerURL.map { try UsageLedger.entries(at: $0, in: interval) } ?? []
        return UsageReport(rows: rows, ledger: ledger, slices: slices, agents: agents)
    }

    /// No `SQLITE_OPEN_CREATE`: a Mac that never chatted gets no rows and no file.
    nonisolated static func rows(
        databaseURL: URL, in interval: DateInterval, slices: [Date] = [],
        runningCostChats: Set<UUID> = []
    ) throws -> [UsageRow] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard
            sqlite3_open_v2(
                databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
                == SQLITE_OK,
            sqlite3_exec(database, "PRAGMA query_only = 1;", nil, nil, nil) == SQLITE_OK
        else { throw Failure.unreadable }
        sqlite3_busy_timeout(database, 1_000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.unreadable
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, interval.end.timeIntervalSince1970)
        let chats = runningCostChats.map { "\"\($0.uuidString)\"" }.joined(separator: ",")
        sqlite3_bind_text(statement, 3, "[\(chats)]", -1, usageSQLiteTransient)
        let starts = (slices.isEmpty ? [interval.start] : slices).map { "\($0.timeIntervalSince1970)" }
        sqlite3_bind_text(statement, 4, "[\(starts.joined(separator: ","))]", -1, usageSQLiteTransient)
        var rows: [UsageRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw Failure.unreadable }
            try Task.checkCancellation()
            guard let row = row(from: statement) else { continue }
            rows.append(row)
        }
    }

    private static func row(from statement: OpaquePointer?) -> UsageRow? {
        guard let id = text(statement, 0).flatMap(UUID.init(uuidString:)) else { return nil }
        func count(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        let totals = UsageTotals(
            replies: count(3), input: count(4), output: count(5), cached: count(6),
            reasoning: count(7),
            cost: sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 8),
            pricedReplies: count(9))
        return UsageRow(
            conversationID: id, modelJSON: text(statement, 1), totals: totals, slice: count(2))
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    /// Each priced ACP reply and the total before it, in any period; a drop is a new session.
    private static let running = """
        running(message_id, before) AS (
            SELECT x.message_id,
                   LAG(x.cost_usd) OVER (PARTITION BY m.conversation_id ORDER BY m.position)
            FROM messages m
            JOIN message_details x ON x.message_id = m.id
            WHERE m.conversation_id IN (SELECT value FROM json_each(?3))
              AND m.role = 'assistant' AND x.cost_usd IS NOT NULL
        )
        """

    /// `CROSS JOIN` pins the plan to a scan of replies with usage, not of every message.
    private static let sql = """
        WITH \(running)
        SELECT m.conversation_id,
               d.model,
               (SELECT MAX(s.key) FROM json_each(?4) s WHERE s.value <= m.sent_at) AS slice,
               COUNT(*),
               SUM(COALESCE(x.input_tokens, 0)),
               SUM(COALESCE(x.output_tokens, 0)),
               SUM(COALESCE(x.cached_tokens, 0)),
               SUM(COALESCE(x.reasoning_tokens, 0)),
               SUM(CASE WHEN r.before <= x.cost_usd THEN x.cost_usd - r.before ELSE x.cost_usd END),
               COUNT(x.cost_usd)
        FROM message_details x
        CROSS JOIN messages m ON m.id = x.message_id
        LEFT JOIN conversation_details d ON d.conversation_id = m.conversation_id
        LEFT JOIN running r ON r.message_id = x.message_id
        WHERE m.role = 'assistant'
          AND m.sent_at >= ?1 AND m.sent_at < ?2
          AND (x.input_tokens IS NOT NULL OR x.output_tokens IS NOT NULL OR x.cost_usd IS NOT NULL)
        GROUP BY m.conversation_id, slice;
        """
}
