import Foundation

/// Notes as an agent tool family: reading is personal data, adding is a change under its rule.
struct NoteAgentTools: AgentToolProvider {
    let repository: NotesRepository
    let timeZone: TimeZone
    let isEnabled: @Sendable () async -> Bool
    let writer: NoteToolWriter

    private static let previewLength = 600

    func specs(for turn: AgentTurn) -> [AgentToolSpec] {
        let appendAsks = AgentConsentPolicy.rule(for: .change, in: .notes, of: turn.profile) == .ask
        return NoteTools.definitions(
            canWrite: turn.profile.access.writes, appendAsks: appendAsks,
            origin: String(localized: "Notes")
        ).map { tool in
            tool.name == NoteTools.append
                ? AgentToolSpec(tool: tool, family: .notes, risk: .change, concurrent: false)
                : AgentToolSpec(tool: tool, family: .notes, risk: .personal, concurrent: true)
        }
    }

    func run(_ call: AIToolCall, in context: AgentToolContext) async -> AIToolResult {
        await NoteToolRunner(
            repository: repository, canWrite: context.turn.profile.access.writes,
            timeZone: timeZone, isEnabled: isEnabled,
            consent: { await context.consent(Self.request(for: $0)) }, writer: writer
        ).run(call)
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
