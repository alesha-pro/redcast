import Foundation
import SQLite3

/// OpenCode's `opencode.db`, read-only; every connection closes before its function returns.
enum OpenCodeStateReader {
    static let requiredColumns: Set<String> = ["id", "directory", "title", "time_created", "time_updated"]

    /// Top-level sessions, newest first; a child session is a subagent's run and never listed.
    static func sessions(database: URL, includeArchived: Bool, limit: Int = 2_000)
        throws(HistoryDatabase.Failure) -> [AgentSession]
    {
        let db = try HistoryDatabase.open(database)
        defer { sqlite3_close_v2(db) }
        let columns = try HistoryDatabase.columns(of: "session", in: db)
        let missing = requiredColumns.subtracting(columns)
        guard missing.isEmpty else { throw .schema(missing.sorted().joined(separator: ", ")) }
        let prompts = try hasParts(db)
        let sql = sessionsQuery(columns: columns, prompts: prompts)
        let rows = try HistoryDatabase.query(sql, in: db) { statement in
            sqlite3_bind_int(statement, 1, includeArchived ? 1 : 0)
            sqlite3_bind_int(statement, 2, Int32(limit))
        }
        return rows.compactMap(session(from:))
    }

    /// The last `limit` turns; one answer spans several assistant messages, one per step.
    static func turns(database: URL, sessionID: String, limit: Int)
        throws(HistoryDatabase.Failure) -> [SessionTurn]
    {
        let db = try HistoryDatabase.open(database)
        defer { sqlite3_close_v2(db) }
        guard try hasParts(db) else { return [] }
        let sql = """
            SELECT m.id, json_extract(m.data, '$.role'), m.time_created,
                   substr(json_extract(p.data, '$.text'), 1, 8192)
            FROM message m JOIN part p ON p.message_id = m.id
            WHERE m.id IN (SELECT id FROM message WHERE session_id = ?1 ORDER BY time_created DESC, id DESC LIMIT ?2)
              AND \(textPart("p"))
            ORDER BY m.time_created, m.id, p.id;
            """
        let rows = try HistoryDatabase.query(sql, in: db) { statement in
            HistoryDatabase.bind(sessionID, at: 1, in: statement)
            sqlite3_bind_int(statement, 2, Int32(limit * 6))
        }
        var turns: [SessionTurn] = []
        var current: (id: String, role: SessionTurn.Role, texts: [String], date: Date?)?
        func close() {
            guard let message = current, !message.texts.isEmpty else { return }
            let text = message.texts.joined(separator: "\n\n")
            if message.role == .assistant, let last = turns.last, last.role == .assistant {
                turns[turns.count - 1] = SessionTurn(
                    role: .assistant, text: AgentSessionText.bounded(last.text + "\n\n" + text), date: last.date)
            } else {
                turns.append(SessionTurn(role: message.role, text: AgentSessionText.bounded(text), date: message.date))
            }
        }
        for row in rows {
            let text = row[3].trimmingCharacters(in: .whitespacesAndNewlines)
            if current?.id != row[0] {
                close()
                guard row[1] == "user" || row[1] == "assistant" else {
                    current = nil
                    continue
                }
                current = (row[0], row[1] == "user" ? .user : .assistant, [], date(row[2]))
            }
            if !text.isEmpty { current?.texts.append(text) }
        }
        close()
        return Array(turns.suffix(limit))
    }

    /// The first text part holding `needle`; SQLite's `lower` folds ASCII only.
    static func match(database: URL, sessionID: String, needle: String)
        throws(HistoryDatabase.Failure) -> String?
    {
        let db = try HistoryDatabase.open(database)
        defer { sqlite3_close_v2(db) }
        guard try HistoryDatabase.columns(of: "part", in: db).isSuperset(of: ["session_id", "data"]) else {
            return nil
        }
        let sql = """
            SELECT json_extract(p.data, '$.text') FROM part p
            WHERE p.session_id = ?1 AND \(textPart("p"))
              AND instr(lower(json_extract(p.data, '$.text')), lower(?2)) > 0
            LIMIT 1;
            """
        let rows = try HistoryDatabase.query(sql, in: db) { statement in
            HistoryDatabase.bind(sessionID, at: 1, in: statement)
            HistoryDatabase.bind(needle, at: 2, in: statement)
        }
        return rows.first?.first
    }

    /// OpenCode names a session `New session - <ISO date>` until it has generated a title.
    static func title(_ title: String, firstPrompt: String) -> (String, AgentSessionTitleOrigin) {
        let line = AgentSessionText.oneLine(title, limit: AgentSessionText.titleLimit)
        if !line.isEmpty, !isPlaceholder(title) { return (line, .generated) }
        let cut = AgentSessionText.promptTitle(firstPrompt)
        return cut.isEmpty ? ("", .untitled) : (cut, .prompt)
    }

    static func isPlaceholder(_ title: String) -> Bool {
        ["New session - ", "Child session - "].contains { prefix in
            title.hasPrefix(prefix) && ClaudeTranscriptDecoder.date(String(title.dropFirst(prefix.count))) != nil
        }
    }

    // MARK: - Rows

    private static func hasParts(_ db: OpaquePointer) throws(HistoryDatabase.Failure) -> Bool {
        let message = try HistoryDatabase.columns(of: "message", in: db)
        let part = try HistoryDatabase.columns(of: "part", in: db)
        return message.isSuperset(of: ["id", "session_id", "time_created", "data"])
            && part.isSuperset(of: ["id", "message_id", "data"])
    }

    /// A text part the person or the model wrote; attached file contents are `synthetic`.
    private static func textPart(_ alias: String) -> String {
        "json_extract(\(alias).data, '$.type') = 'text'"
            + " AND COALESCE(json_extract(\(alias).data, '$.synthetic'), 0) = 0"
            + " AND COALESCE(json_extract(\(alias).data, '$.ignored'), 0) = 0"
    }

    /// The first or last prompt of a session, from its messages' text parts, cut in SQL.
    private static func prompt(newest: Bool) -> String {
        let order = newest ? "DESC" : "ASC"
        return """
            (SELECT substr(json_extract(p.data, '$.text'), 1, 400) FROM message m JOIN part p ON p.message_id = m.id
             WHERE m.session_id = s.id AND json_extract(m.data, '$.role') = 'user' AND \(textPart("p"))
             ORDER BY m.time_created \(order), m.id \(order), p.id LIMIT 1)
            """
    }

    private static func sessionsQuery(columns: Set<String>, prompts: Bool) -> String {
        let archived = columns.contains("time_archived") ? "(s.time_archived IS NOT NULL)" : "0"
        let first = prompts ? "COALESCE(\(prompt(newest: false)), '')" : "''"
        let last = prompts ? "COALESCE(\(prompt(newest: true)), '')" : "''"
        var conditions = ["(?1 = 1 OR \(archived) = 0)"]
        if columns.contains("parent_id") { conditions.append("s.parent_id IS NULL") }
        return """
            SELECT s.id, COALESCE(s.directory, ''), substr(COALESCE(s.title, ''), 1, 400), s.time_created,
                   s.time_updated, \(archived), \(first), \(last)
            FROM session s WHERE \(conditions.joined(separator: " AND "))
            ORDER BY s.time_updated DESC LIMIT ?2;
            """
    }

    /// A session with neither a title of its own nor a prompt was opened and left empty.
    private static func session(from row: [String]) -> AgentSession? {
        let first = AgentSessionText.oneLine(row[6])
        let (title, origin) = self.title(row[2], firstPrompt: first)
        guard !row[0].isEmpty, origin != .untitled else { return nil }
        let created = date(row[3]) ?? .distantPast
        return AgentSession(
            source: .openCode, sessionID: row[0], title: title, titleOrigin: origin, firstPrompt: first,
            lastPrompt: AgentSessionText.oneLine(row[7]), directory: row[1].isEmpty ? nil : row[1],
            createdAt: created, updatedAt: date(row[4]) ?? created, host: .terminal, isArchived: row[5] == "1")
    }

    private static func date(_ milliseconds: String) -> Date? {
        Double(milliseconds).map { Date(timeIntervalSince1970: $0 / 1_000) }
    }
}
