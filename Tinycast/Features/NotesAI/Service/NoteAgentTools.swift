import Foundation

/// Notes as an agent tool family: reading is personal data, adding is a change that always asks.
struct NoteAgentTools: AgentToolProvider {
    let repository: NotesRepository
    let timeZone: TimeZone
    let isEnabled: @Sendable () async -> Bool
    let writer: NoteToolWriter

    private static let previewLength = 600

    func specs(for turn: AgentTurn) -> [AgentToolSpec] {
        NoteTools.definitions(canWrite: turn.profile.access.writes, origin: String(localized: "Notes"))
            .map { tool in
                tool.name == NoteTools.append
                    ? AgentToolSpec(tool: tool, family: .notes, risk: .change, concurrent: false)
                    : AgentToolSpec(tool: tool, family: .notes, risk: .personal, concurrent: true)
            }
    }

    func run(_ call: AIToolCall, in context: AgentToolContext) async -> AIToolResult {
        // A read asks only under a rule of ask, as in an Ask Every Time chat; by default it runs.
        if call.name != NoteTools.append, await !context.consent(Self.readRequest(for: call)) {
            return .failure(call.id, NoteToolRunner.declined)
        }
        return await NoteToolRunner(
            repository: repository, canWrite: context.turn.profile.access.writes,
            timeZone: timeZone, isEnabled: isEnabled,
            consent: { await context.consent(Self.request(for: $0)) }, writer: writer
        ).run(call)
    }

    static func readRequest(for call: AIToolCall) -> AgentConsentRequest {
        let arguments = JSONValue(data: Data(call.arguments.utf8))?.objectValue ?? [:]
        let query = arguments["query"]?.stringValue ?? ""
        let summary =
            call.name == NoteTools.search
            ? query.isEmpty
                ? String(localized: "List your newest notes") : String(localized: "Search your notes for “\(query)”")
            : String(localized: "Read the note “\(arguments["note"]?.stringValue ?? "")”")
        return AgentConsentRequest(summary: summary, detail: "")
    }

    static func request(for consent: NoteToolConsent) -> AgentConsentRequest {
        let preview =
            consent.text.count <= previewLength
            ? consent.text : String(consent.text.prefix(previewLength)) + "…"
        return AgentConsentRequest(
            summary: consent.creates
                ? String(localized: "Create the note “\(consent.title)”")
                : String(localized: "Add to “\(consent.title)”"),
            detail: preview + "\n\n" + Int64(consent.text.utf8.count).formatted(.byteCount(style: .file)))
    }
}
