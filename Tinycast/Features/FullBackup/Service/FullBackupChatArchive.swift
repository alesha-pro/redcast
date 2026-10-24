import Foundation
import SQLite3

private let chatArchiveTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The chat database copied whole and merged back row by row, so its schema is never restated.
enum FullBackupChatArchive {
    enum ArchiveError: LocalizedError {
        case unreadable

        var errorDescription: String? { String(localized: "Couldn't read the chat history.") }
    }

    /// `VACUUM INTO` folds the WAL in, so the copy is consistent while the app keeps writing.
    static func snapshot(_ source: URL, to destination: URL) throws {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard FileManager.default.fileExists(atPath: source.path),
            sqlite3_open_v2(source.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { throw ArchiveError.unreadable }
        sqlite3_busy_timeout(database, 5_000)
        try run("VACUUM INTO ?;", binding: destination.path, in: database)
    }

    /// Rows whose key is already here are kept as they are; returns the conversations added.
    static func merge(_ backup: URL, into target: URL) throws -> Int {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(target.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw ArchiveError.unreadable
        }
        sqlite3_busy_timeout(database, 5_000)
        // The attached file came from elsewhere: only its tables are read, and its schema is untrusted.
        try run("PRAGMA trusted_schema = OFF;", in: database)
        try run("ATTACH DATABASE ? AS backup;", binding: backup.path, in: database)
        defer { sqlite3_exec(database, "DETACH DATABASE backup;", nil, nil, nil) }
        let before = count("conversations", in: database)
        try run("BEGIN IMMEDIATE;", in: database)
        do {
            for table in tables(in: "main", database) where tables(in: "backup", database).contains(table) {
                let columns = Set(columnNames(table, in: "backup", database))
                let shared = columnNames(table, in: "main", database).filter(columns.contains)
                guard !shared.isEmpty else { continue }
                let list = shared.map(quoted).joined(separator: ", ")
                try run(
                    "INSERT OR IGNORE INTO main.\(quoted(table)) (\(list)) "
                        + "SELECT \(list) FROM backup.\(quoted(table));", in: database)
            }
            try run("COMMIT;", in: database)
        } catch {
            sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            throw error
        }
        return max(count("conversations", in: database) - before, 0)
    }

    static func conversationCount(at url: URL) -> Int {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        return count("conversations", in: database)
    }

    // MARK: - SQLite

    private static func run(
        _ sql: String, binding value: String? = nil, in database: OpaquePointer?
    ) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ArchiveError.unreadable
        }
        if let value { sqlite3_bind_text(statement, 1, value, -1, chatArchiveTransient) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw ArchiveError.unreadable }
    }

    private static func tables(in schema: String, _ database: OpaquePointer?) -> [String] {
        strings(
            "SELECT name FROM \(schema).sqlite_master WHERE type = 'table' "
                + "AND name NOT LIKE 'sqlite_%' ORDER BY name;", in: database)
    }

    private static func columnNames(
        _ table: String, in schema: String, _ database: OpaquePointer?
    ) -> [String] {
        strings("SELECT name FROM pragma_table_info(\(literal(table)), \(literal(schema)));", in: database)
    }

    private static func count(_ table: String, in database: OpaquePointer?) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM main.\(quoted(table));", -1, &statement, nil)
            == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW
        else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func strings(_ sql: String, in database: OpaquePointer?) -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { values.append(String(cString: text)) }
        }
        return values
    }

    private static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
