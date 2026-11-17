import Foundation
import SQLite3

/// Another tool's SQLite history, opened read-only; each caller closes it before it returns.
enum HistoryDatabase {
    enum Failure: Error, Equatable { case missing, unreadable(String), schema(String) }

    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func open(_ url: URL) throws(Failure) -> OpaquePointer {
        guard FileManager.default.fileExists(atPath: url.path) else { throw .missing }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(db)
            throw .unreadable(message)
        }
        sqlite3_busy_timeout(db, 250)
        sqlite3_exec(db, "PRAGMA query_only = 1;", nil, nil, nil)
        return db
    }

    /// Empty for a table that does not exist, so a reader can probe before it queries.
    static func columns(of table: String, in db: OpaquePointer) throws(Failure) -> Set<String> {
        let rows = try query("PRAGMA table_info(\(table));", in: db) { _ in }
        return Set(rows.map { $0[1] })
    }

    /// Every column as text; the callers convert, so one reader serves every query.
    static func query(
        _ sql: String, in db: OpaquePointer, bind: (OpaquePointer) -> Void
    ) throws(Failure) -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw .unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        var rows: [[String]] = []
        while true {
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW else {
                guard step == SQLITE_DONE else { throw .unreadable(String(cString: sqlite3_errmsg(db))) }
                return rows
            }
            let count = sqlite3_column_count(statement)
            rows.append(
                (0..<count).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                })
        }
    }

    static func bind(_ text: String, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, text, -1, transient)
    }
}
