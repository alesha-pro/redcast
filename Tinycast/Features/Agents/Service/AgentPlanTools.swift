import Foundation

/// `update_plan`: the model resends its whole checklist, shown as an ACP plan is and kept nowhere.
struct AgentPlanTools: AgentToolProvider {
    func specs(for turn: AgentTurn) -> [AgentToolSpec] {
        [
            AgentToolSpec(
                tool: AgentPlan.definition(origin: turn.profile.name), family: nil, risk: .own,
                concurrent: false)
        ]
    }

    func run(_ call: AIToolCall, in context: AgentToolContext) async -> AIToolResult {
        guard let items = AgentPlan.items(in: call.arguments) else {
            return .failure(call.id, AgentPlan.malformed)
        }
        context.signal(.reasoning(AgentPlan.checklist(items)))
        return AIToolResult(callID: call.id, content: "Plan updated.", isError: false)
    }
}
