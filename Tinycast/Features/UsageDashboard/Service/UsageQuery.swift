import Foundation
import SQLite3

/// One aggregate over chat history per period, on a read-only connection opened for it alone.
enum UsageQuery {
    enum Failure: Error, Equatable {
        case unreadable
    }

    @concurrent
    static func report(
        databaseURL: URL, in interval: DateInterval, agents: [UUID: UUID]
    ) async throws -> UsageReport {
        UsageReport(rows: try rows(databaseURL: databaseURL, in: interval), agents: agents)
    }

    /// No `SQLITE_OPEN_CREATE`: a Mac that never chatted gets no rows and no file.
    nonisolated static func rows(databaseURL: URL, in interval: DateInterval) throws -> [UsageRow] {
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
            replies: count(2), input: count(3), output: count(4), cached: count(5),
            reasoning: count(6),
            cost: sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 7),
            pricedReplies: count(8))
        return UsageRow(conversationID: id, modelJSON: text(statement, 1), totals: totals)
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    /// `CROSS JOIN` pins the plan to a scan of replies with usage, not of every message.
    private static let sql = """
        SELECT m.conversation_id,
               d.model,
               COUNT(*),
               SUM(COALESCE(x.input_tokens, 0)),
               SUM(COALESCE(x.output_tokens, 0)),
               SUM(COALESCE(x.cached_tokens, 0)),
               SUM(COALESCE(x.reasoning_tokens, 0)),
               SUM(x.cost_usd),
               COUNT(x.cost_usd)
        FROM message_details x
        CROSS JOIN messages m ON m.id = x.message_id
        LEFT JOIN conversation_details d ON d.conversation_id = m.conversation_id
        WHERE m.role = 'assistant'
          AND m.sent_at >= ?1 AND m.sent_at < ?2
          AND (x.input_tokens IS NOT NULL OR x.output_tokens IS NOT NULL OR x.cost_usd IS NOT NULL)
        GROUP BY m.conversation_id;
        """
}
