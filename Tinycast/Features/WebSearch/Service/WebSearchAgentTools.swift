import Foundation

/// The Web family's `web_search`, on the engines in Settings; `web_fetch` always rides beside it.
struct WebSearchAgentTools: AgentToolProvider {
    let runner: WebSearchRunner

    func specs(for turn: AgentTurn) -> [AgentToolSpec] {
        [
            AgentToolSpec(
                tool: WebSearchTool.definition(origin: turn.profile.name), family: .web, risk: .network,
                concurrent: true)
        ]
    }

    func run(_ call: AIToolCall, in context: AgentToolContext) async -> AIToolResult {
        guard let query = WebSearchTool.parse(call.arguments) else {
            return .failure(call.id, WebSearchTool.missingQuery)
        }
        guard !runner.chain.isEmpty else { return .failure(call.id, WebSearchTool.noEngines) }
        let request = AgentConsentRequest(
            summary: String(localized: "Search the web for “\(query.text)”"), detail: "")
        guard await context.consent(request) else {
            return .failure(call.id, "The user declined this. Ask what they would like instead.")
        }
        context.signal(.searching(query.text))
        let result = await runner.answer(query, callID: call.id)
        context.signal(.searched(query.text))
        return result
    }
}
