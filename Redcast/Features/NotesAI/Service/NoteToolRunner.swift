import Foundation

/// What an append asks the user to allow; the provider words the dialog.
struct NoteToolConsent: Sendable, Equatable {
    let title: String
    let creates: Bool
    let text: String
}

/// Where an append lands when the editor has that note open, so the next autosave cannot drop it.
struct NoteToolWriter: Sendable {
    /// Given the file's text; true when the open note's draft took the change, false sends it on.
    var amendOpenDraft: @Sendable (NoteID, String, @escaping @Sendable (String) -> String) async -> Bool
    /// After a file write, so a loaded store re-lists and an open clean note reloads.
    var didWrite: @Sendable (NoteID) async -> Void

    static let fileOnly = NoteToolWriter(amendOpenDraft: { _, _, _ in false }, didWrite: { _ in })

    /// The store owns an unsaved or current draft, so such a note is amended there, never on disk.
    static func through(_ store: NotesStore) -> NoteToolWriter {
        NoteToolWriter(
            amendOpenDraft: { @MainActor [weak store] id, onDisk, change in
                store?.amendDraft(of: id, onDisk: onDisk, change) ?? false
            },
            didWrite: { @MainActor [weak store] _ in
                guard let store, store.isLoaded else { return }
                _ = await store.reload()
            })
    }
}

/// Runs one Notes call off-main against the folder; a refusal comes back as text the model reads.
nonisolated struct NoteToolRunner: Sendable {
    let repository: NotesRepository
    let canWrite: Bool
    let timeZone: TimeZone
    let isEnabled: @Sendable () async -> Bool
    let consent: @Sendable (NoteToolConsent) async -> Bool
    let writer: NoteToolWriter

    static let turnedOff = "Notes is turned off in Redcast's settings."
    static let declined = "The user declined this. Ask what they would like instead."

    func run(_ call: AIToolCall) async -> AIToolResult {
        guard await isEnabled() else { return .failure(call.id, Self.turnedOff) }
        let arguments = JSONValue(data: Data(call.arguments.utf8))?.objectValue ?? [:]
        let outcome: Result<String, Failure>
        switch call.name {
        case NoteTools.search: outcome = search(arguments)
        case NoteTools.read: outcome = read(arguments)
        case NoteTools.append: outcome = await append(arguments)
        default: outcome = .failure(Failure("There is no tool called \(call.name)."))
        }
        switch outcome {
        case .success(let text):
            return AIToolResult(
                callID: call.id, content: NoteToolFormat.capped(text, bytes: NoteTools.maxOutputBytes),
                isError: false)
        case .failure(let failure): return .failure(call.id, failure.message)
        }
    }

    // MARK: - Search

    private func search(_ arguments: [String: JSONValue]) -> Result<String, Failure> {
        let limit = min(
            NoteTools.maxSearchLimit,
            max(1, NoteToolFormat.integer(arguments["limit"]) ?? NoteTools.defaultSearchLimit))
        let summaries: [NoteSummary]
        switch list() {
        case .success(let listed): summaries = listed
        case .failure(let failure): return .failure(failure)
        }
        let raw = arguments["query"]?.stringValue ?? ""
        let query = NoteSearch.Query(raw)
        guard !query.isEmpty else { return .success(newest(summaries, limit: limit)) }
        var matches: [(result: NoteSearchResult, snippet: String?)] = []
        for summary in summaries {
            if Task.isCancelled { break }
            // An unreadable body still lets its title match, so one bad file never ends the search.
            let source = try? repository.load(summary.id).source
            guard let result = NoteSearch.match(query: query, summary: summary, source: source) else {
                continue
            }
            matches.append((result, source.flatMap { NoteToolFormat.snippet(in: $0, terms: query.terms) }))
        }
        guard !matches.isEmpty else { return .success("No note matches “\(raw)”.") }
        matches.sort { NoteSearch.precedes($0.result, $1.result) }
        var lines = [
            matches.count == 1 ? "1 note matches “\(raw)”:" : "\(matches.count) notes match “\(raw)”:"
        ]
        for match in matches.prefix(limit) {
            lines.append("- " + NoteToolFormat.row(match.result.summary, timeZone: timeZone))
            if let snippet = match.snippet { lines.append("  > " + snippet) }
        }
        if matches.count > limit {
            lines.append("… \(matches.count - limit) more; add words to narrow the search.")
        }
        lines.append("Read one with notes_read.")
        return .success(lines.joined(separator: "\n"))
    }

    private func newest(_ summaries: [NoteSummary], limit: Int) -> String {
        guard !summaries.isEmpty else { return "There are no notes yet." }
        let shown = summaries.prefix(limit)
        var lines = [shown.count == 1 ? "The newest note:" : "The \(shown.count) newest notes:"]
        lines += shown.map { "- " + NoteToolFormat.row($0, timeZone: timeZone) }
        if summaries.count > limit {
            lines.append("… \(summaries.count - limit) older; search by words to find them.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Read

    private func read(_ arguments: [String: JSONValue]) -> Result<String, Failure> {
        guard let raw = arguments["note"]?.stringValue,
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .failure(.missing("note")) }
        let summary: NoteSummary
        switch list().flatMap({ find(raw, in: $0) }) {
        case .success(let found): summary = found
        case .failure(let failure): return .failure(failure)
        }
        let source: String
        do {
            source = try repository.load(summary.id).source
        } catch {
            return .failure(Failure(error))
        }
        var lines = source.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let count = lines.count == 1 ? "1 line" : "\(lines.count) lines"
        let header =
            "Note: \(summary.displayTitle) (\(summary.id.rawValue)) · modified "
            + "\(NoteToolFormat.timestamp(summary.modifiedAt, in: timeZone)) · \(count)\n---\n"
        guard !lines.isEmpty else { return .success(header + "(empty)") }
        let offset = max(1, NoteToolFormat.integer(arguments["offset"]) ?? 1)
        let limit = min(
            NoteTools.maxLines, max(1, NoteToolFormat.integer(arguments["limit"]) ?? NoteTools.maxLines))
        guard offset <= lines.count else {
            return .failure(
                Failure("“\(summary.displayTitle)” has \(count); offset \(offset) is past the end."))
        }
        // Room for the continuation line, so the cut can always say where to go on.
        let budget = NoteTools.maxOutputBytes - 96
        var output = header
        var used = header.utf8.count
        var line = offset
        let last = min(lines.count, offset + limit - 1)
        while line <= last {
            let next = lines[line - 1] + "\n"
            guard used + next.utf8.count <= budget else { break }
            output += next
            used += next.utf8.count
            line += 1
        }
        if line == offset {
            output += NoteToolFormat.capped(lines[line - 1], bytes: budget - used) + "\n"
            line += 1
        }
        if line <= lines.count {
            output += "… \(lines.count - line + 1) more lines; continue with offset \(line)."
        }
        return .success(output)
    }

    // MARK: - Append

    private func append(_ arguments: [String: JSONValue]) async -> Result<String, Failure> {
        guard canWrite else { return .failure(Failure("This agent is read-only and cannot change notes.")) }
        guard let raw = arguments["note"]?.stringValue,
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .failure(.missing("note")) }
        guard let text = arguments["text"]?.stringValue,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .failure(.missing("text")) }
        guard text.utf8.count <= NoteTools.maxAppendBytes else {
            return .failure(Failure("text is over 64 KB; add it in parts."))
        }
        let summaries: [NoteSummary]
        switch list() {
        case .success(let listed): summaries = listed
        case .failure(let failure): return .failure(failure)
        }
        let creates = arguments["create"]?.boolValue ?? true
        let target: NoteSummary?
        let title: String
        switch find(raw, in: summaries) {
        case .success(let found):
            target = found
            title = found.displayTitle
        case .failure(let failure):
            guard creates, failure.isMissing else { return .failure(failure) }
            guard let fresh = NoteToolFormat.newTitle(raw) else {
                return .failure(Failure("“\(raw)” can't be a note's title."))
            }
            // A title the folder had to change may already name a note.
            if case .found(let existing) = NoteToolFormat.resolve(fresh, in: summaries) {
                target = existing
                title = existing.displayTitle
            } else {
                target = nil
                title = fresh
            }
        }
        let request = NoteToolConsent(title: title, creates: target == nil, text: text)
        guard await consent(request) else { return .failure(Failure(Self.declined)) }
        // The dialog can stay up for a while, and Notes may have been switched off under it.
        guard await isEnabled() else { return .failure(Failure(Self.turnedOff)) }
        let size = Self.size(text.utf8.count)
        guard let target else { return await create(title, text: text) }
        let change: @Sendable (String) -> String = { NoteToolFormat.appending(text, to: $0) }
        let current: String
        do {
            current = try repository.load(target.id).source
        } catch {
            return .failure(Failure(error))
        }
        if await writer.amendOpenDraft(target.id, current, change) {
            return .success("Added \(size) to “\(title)”.")
        }
        do {
            try repository.save(id: target.id, source: change(current))
        } catch {
            return .failure(Failure(error))
        }
        await writer.didWrite(target.id)
        return .success("Added \(size) to “\(title)”.")
    }

    private func create(_ title: String, text: String) async -> Result<String, Failure> {
        let document: NoteDocument
        do {
            document = try repository.create(title: title)
            try repository.save(id: document.id, source: NoteToolFormat.appending(text, to: ""))
        } catch {
            return .failure(Failure(error))
        }
        await writer.didWrite(document.id)
        let created = (document.id.rawValue as NSString).deletingPathExtension
        return .success("Created “\(created)” (\(document.id.rawValue)).")
    }

    // MARK: - Lookup

    private func list() -> Result<[NoteSummary], Failure> {
        do {
            return .success(try repository.list())
        } catch {
            return .failure(Failure(error))
        }
    }

    private func find(_ raw: String, in summaries: [NoteSummary]) -> Result<NoteSummary, Failure> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch NoteToolFormat.resolve(name, in: summaries) {
        case .found(let summary):
            return .success(summary)
        case .ambiguous(let candidates):
            let listed = candidates.prefix(NoteToolFormat.maxSuggestions)
                .map { "\($0.displayTitle) (\($0.id.rawValue))" }.joined(separator: ", ")
            return .failure(
                Failure("Several notes are called “\(name)”: \(listed). Name one by its file name."))
        case .missing(let suggestions):
            let close = suggestions.isEmpty ? "" : " Close titles: \(suggestions.joined(separator: ", "))."
            return .failure(
                Failure("No note is called “\(name)”.\(close) notes_search finds others.", isMissing: true))
        }
    }

    /// Bytes in English whatever the Mac's language, since only the model reads them.
    private static func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(Locale(identifier: "en_US_POSIX")))
    }

    struct Failure: Error, Sendable {
        let message: String
        var isMissing = false

        init(_ message: String, isMissing: Bool = false) {
            self.message = message
            self.isMissing = isMissing
        }

        /// English for the model, where the repository's own text is in the Mac's language.
        init(_ error: any Error) {
            switch error as? NotesRepository.Failure {
            case .invalidTitle(let title)?: message = "“\(title)” can't be a note's title."
            case .unreadable(let url)?: message = "\(url.lastPathComponent) is not UTF-8 text."
            case .invalidLocation(let url)?: message = "\(url.lastPathComponent) is not in the notes folder."
            case .io(let url, let detail)?: message = "\(url.lastPathComponent) could not be used: \(detail)"
            case nil: message = error.localizedDescription
            }
        }

        static func missing(_ argument: String) -> Self { Self("The \(argument) argument is required.") }
    }
}
