import Foundation
import SQLite3

private let codexSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Codex's own databases, read-only; every connection closes before its function returns.
enum CodexStateReader {
    enum Failure: Error, Equatable { case missing, unreadable(String), schema(String) }

    static let requiredColumns: Set<String> = ["id", "cwd", "rollout_path", "created_at", "updated_at"]

    /// Visible, non-subagent threads, newest first; columns probed with PRAGMA table_info.
    static func threads(database: URL, includeArchived: Bool, limit: Int = 2_000)
        throws(Failure) -> [AgentSession]
    {
        let db = try open(database)
        defer { sqlite3_close_v2(db) }
        let columns = try self.columns(of: "threads", in: db)
        let missing = requiredColumns.subtracting(columns)
        guard missing.isEmpty else { throw .schema(missing.sorted().joined(separator: ", ")) }
        let sql = threadsQuery(columns: columns, single: false)
        let rows = try query(sql, in: db) { statement in
            sqlite3_bind_int(statement, 1, includeArchived ? 1 : 0)
            sqlite3_bind_int(statement, 2, Int32(limit))
        }
        return rows.compactMap { session(from: $0, listing: true) }
    }

    /// Any thread, listed or not, so an event can tell a subagent or Tinycast's own thread apart.
    static func thread(database: URL, id: String) throws(Failure) -> AgentSession? {
        let db = try open(database)
        defer { sqlite3_close_v2(db) }
        let columns = try self.columns(of: "threads", in: db)
        guard requiredColumns.isSubset(of: columns) else { throw .schema("threads") }
        let sql = threadsQuery(columns: columns, single: true)
        let rows = try query(sql, in: db) { statement in
            sqlite3_bind_text(statement, 1, id, -1, codexSQLiteTransient)
        }
        return rows.first.flatMap { session(from: $0, listing: false) }
    }

    /// From thread_history's projected items; empty when the thread has none.
    static func historyTurns(database: URL, threadID: String, limit: Int) throws(Failure) -> [SessionTurn] {
        let db = try open(database)
        defer { sqlite3_close_v2(db) }
        guard try columns(of: "thread_items", in: db).isSuperset(of: ["item_type", "item_json"]) else {
            return []
        }
        let sql = """
            SELECT item_type, item_json, created_at_ms FROM thread_items
            WHERE thread_id = ?1 AND item_type IN ('userMessage', 'agentMessage')
            ORDER BY rollout_ordinal DESC LIMIT ?2;
            """
        let rows = try query(sql, in: db) { statement in
            sqlite3_bind_text(statement, 1, threadID, -1, codexSQLiteTransient)
            sqlite3_bind_int(statement, 2, Int32(limit))
        }
        return rows.reversed().compactMap { row in
            guard let data = row[1].data(using: .utf8),
                let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let text = itemText(item, user: row[0] == "userMessage")
            else { return nil }
            let date = Double(row[2]).map { Date(timeIntervalSince1970: $0 / 1_000) }
            return SessionTurn(
                role: row[0] == "userMessage" ? .user : .assistant, text: AgentSessionText.bounded(text),
                date: date)
        }
    }

    /// The first projected message holding `needle`, or nil; SQLite's `lower` folds ASCII only.
    static func historyMatch(database: URL, threadID: String, needle: String) throws(Failure) -> String? {
        let db = try open(database)
        defer { sqlite3_close_v2(db) }
        let sql = """
            SELECT item_type, item_json FROM thread_items WHERE thread_id = ?1 AND
              item_type IN ('userMessage','agentMessage') AND instr(lower(item_json), lower(?2)) > 0
            LIMIT 1;
            """
        let rows = try query(sql, in: db) { statement in
            sqlite3_bind_text(statement, 1, threadID, -1, codexSQLiteTransient)
            sqlite3_bind_text(statement, 2, needle, -1, codexSQLiteTransient)
        }
        guard let row = rows.first, let data = row[1].data(using: .utf8),
            let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return itemText(item, user: row[0] == "userMessage")
    }

    static func rolloutTurns(_ window: Data, startsMidLine: Bool, limit: Int) -> [SessionTurn] {
        var events: [SessionTurn] = []
        var responses: [SessionTurn] = []
        for line in ClaudeTranscriptDecoder.lines(of: window, startsMidLine: startsMidLine) {
            guard let object = ClaudeTranscriptDecoder.object(line),
                let payload = object["payload"] as? [String: Any]
            else { continue }
            let date = (object["timestamp"] as? String).flatMap(ClaudeTranscriptDecoder.date)
            switch (object["type"] as? String, payload["type"] as? String) {
            case ("event_msg", "item_completed"):
                guard let item = payload["item"] as? [String: Any], let type = item["type"] as? String,
                    type == "UserMessage" || type == "AgentMessage",
                    let text = joinedText(item["content"])
                else { continue }
                append(text, user: type == "UserMessage", date: date, to: &events)
            case ("event_msg", "user_message"), ("event_msg", "agent_message"):
                guard let text = payload["message"] as? String else { continue }
                append(text, user: payload["type"] as? String == "user_message", date: date, to: &events)
            case ("response_item", "message"):
                guard let role = payload["role"] as? String, role == "user" || role == "assistant",
                    let text = joinedText(payload["content"])
                else { continue }
                append(text, user: role == "user", date: date, to: &responses)
            default:
                continue
            }
        }
        // Both shapes describe the same turns; the event stream is the one the TUI shows.
        return Array((events.isEmpty ? responses : events).suffix(limit))
    }

    /// A subagent or a guardian review is the agent's own run, so it reads as automated.
    static func host(source: String, threadSource: String, originator: String) -> AgentSessionHost {
        if originator == tinycastOriginator { return .tinycast }
        if source == "exec" || source.hasPrefix("{") || threadSource == "automation"
            || hiddenThreadSources.contains(threadSource)
        {
            return .automated
        }
        if threadSource == "realtime_voice" || threadSource == "voice_chat" { return .codexApp }
        switch source {
        case "cli": return .terminal
        case "vscode": return originator.contains("Desktop") ? .codexApp : .editor
        default: return .terminal
        }
    }

    static func title(name: String, title: String, firstMessage: String, preview: String)
        -> (String, AgentSessionTitleOrigin)
    {
        let name = AgentSessionText.oneLine(name, limit: AgentSessionText.titleLimit)
        if !name.isEmpty { return (name, .named) }
        let generated = AgentSessionText.oneLine(title, limit: AgentSessionText.titleLimit)
        if !generated.isEmpty, title != firstMessage { return (generated, .generated) }
        let prompt = preview.isEmpty ? firstMessage : preview
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let cut = AgentSessionText.promptTitle(firstLine)
        return cut.isEmpty ? ("", .untitled) : (cut, .prompt)
    }

    /// What the agent itself wrote into a user turn: instructions and context, never a prompt.
    static let contextPrefixes = ["<environment_context>", "<user_instructions>", "# AGENTS.md instructions"]

    // MARK: - Rows

    private static let hiddenThreadSources: Set<String> = ["guardian_review", "subagent"]
    /// The `clientInfo` name Tinycast's own Codex app-server chats run under.
    private static let tinycastOriginator = "tinycast"

    private static func session(from row: [String], listing: Bool) -> AgentSession? {
        let (id, cwd, rollout) = (row[0], row[1], row[2])
        let (name, title, first, preview) = (row[5], row[6], row[7], row[8])
        let (source, threadSource, originator, branch) = (row[9], row[10], row[11], row[12])
        let hidden = hiddenThreadSources.contains(threadSource) || originator == tinycastOriginator
        guard !id.isEmpty, !(listing && hidden) else { return nil }
        let (display, origin) = self.title(name: name, title: title, firstMessage: first, preview: preview)
        let created = Date(timeIntervalSince1970: (Double(row[3]) ?? 0) / 1_000)
        return AgentSession(
            source: .codex, sessionID: id, title: display, titleOrigin: origin,
            firstPrompt: AgentSessionText.oneLine(first.isEmpty ? preview : first),
            directory: cwd.isEmpty ? nil : cwd, branch: branch.isEmpty ? nil : branch,
            createdAt: created, updatedAt: Date(timeIntervalSince1970: (Double(row[4]) ?? 0) / 1_000),
            host: host(source: source, threadSource: threadSource, originator: originator),
            transcriptPath: rollout.isEmpty ? nil : rollout, isArchived: row[13] != "0")
    }

    /// Optional columns read as '' or 0, so an older or newer schema still lists its threads.
    private static func threadsQuery(columns: Set<String>, single: Bool) -> String {
        func text(_ column: String, cut: Int? = nil) -> String {
            guard columns.contains(column) else { return "''" }
            let value = "COALESCE(\(column), '')"
            return cut.map { "substr(\(value), 1, \($0))" } ?? value
        }
        func milliseconds(_ column: String) -> String {
            columns.contains(column + "_ms") ? "COALESCE(\(column)_ms, \(column) * 1000)" : "\(column) * 1000"
        }
        let archived = columns.contains("archived") ? "COALESCE(archived, 0)" : "0"
        let select = [
            "id", "COALESCE(cwd, '')", "COALESCE(rollout_path, '')", milliseconds("created_at"),
            milliseconds("updated_at"), text("name", cut: 200), text("title", cut: 400),
            text("first_user_message", cut: 400), text("preview", cut: 400), text("source"),
            text("thread_source"), text("originator"), text("git_branch"), archived
        ]
        let head = "SELECT \(select.joined(separator: ", ")) FROM threads WHERE "
        guard !single else { return head + "id = ?1 LIMIT 1;" }
        // The predicate Codex's own visible-thread indexes use: subagents carry a JSON source.
        var conditions = ["(?1 = 1 OR \(archived) = 0)"]
        if columns.contains("preview") { conditions.append("preview <> ''") }
        if columns.contains("source") { conditions.append("source NOT LIKE '{%'") }
        return head + conditions.joined(separator: " AND ") + " ORDER BY updated_at DESC LIMIT ?2;"
    }

    // MARK: - SQLite

    private static func open(_ url: URL) throws(Failure) -> OpaquePointer {
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

    private static func columns(of table: String, in db: OpaquePointer) throws(Failure) -> Set<String> {
        let rows = try query("PRAGMA table_info(\(table));", in: db) { _ in }
        return Set(rows.map { $0[1] })
    }

    /// Every column as text; the callers convert, so one reader serves every query here.
    private static func query(
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

    // MARK: - Items

    private static func itemText(_ item: [String: Any], user: Bool) -> String? {
        let text = user ? joinedText(item["content"]) : item["text"] as? String
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !contextPrefixes.contains(where: trimmed.hasPrefix) else { return nil }
        return trimmed
    }

    private static func joinedText(_ content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return content as? String }
        let texts = blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String,
                ["text", "Text", "input_text", "output_text"].contains(type)
            else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    private static func append(_ text: String, user: Bool, date: Date?, to turns: inout [SessionTurn]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !contextPrefixes.contains(where: trimmed.hasPrefix) else { return }
        turns.append(
            SessionTurn(role: user ? .user : .assistant, text: AgentSessionText.bounded(trimmed), date: date))
    }
}
