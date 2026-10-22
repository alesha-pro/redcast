import Foundation

/// One turn's tools: what the model is offered and where each call goes. Built on main, run off it.
struct AgentToolset: Sendable {
    private enum Route: Sendable {
        case agent(any AgentToolProvider, AgentToolSpec, AgentConsentRule)
        case mcp
    }

    /// Providers in order, each in its own order, then MCP's: the same bytes every round.
    let tools: [AITool]
    private let routes: [String: Route]
    private let turn: AgentTurn
    private let mcp: @Sendable (AIToolCall) async -> AIToolResult
    private let ask: @Sendable (AgentToolSpec, AgentConsentRequest) async -> Bool

    init(
        turn: AgentTurn, providers: [any AgentToolProvider], mcpTools: [AITool],
        mcp: @escaping @Sendable (AIToolCall) async -> AIToolResult,
        ask: @escaping @Sendable (AgentToolSpec, AgentConsentRequest) async -> Bool
    ) {
        var tools: [AITool] = []
        var routes: [String: Route] = [:]
        for provider in providers {
            for spec in provider.specs(for: turn) where routes[spec.tool.name] == nil {
                guard spec.family.map({ turn.profile.tools.contains($0) }) ?? true,
                    spec.risk.isOffered(to: turn.profile.access)
                else { continue }
                let rule = AgentConsentPolicy.rule(for: spec.risk, of: turn.profile)
                guard rule != .never else { continue }
                tools.append(spec.tool)
                routes[spec.tool.name] = .agent(provider, spec, rule)
            }
        }
        for tool in mcpTools where routes[tool.name] == nil {
            tools.append(tool)
            routes[tool.name] = .mcp
        }
        self.tools = tools
        self.routes = routes
        self.turn = turn
        self.mcp = mcp
        self.ask = ask
    }

    /// A call that may share a round: no effect, and a rule that never stops to ask.
    func isConcurrent(_ name: String) -> Bool {
        guard case .agent(_, let spec, let rule)? = routes[name] else { return false }
        return spec.concurrent && rule == .always
    }

    func run(
        _ call: AIToolCall, signal: @escaping @Sendable (AgentToolSignal) -> Void
    ) async -> AIToolResult {
        switch routes[call.name] {
        case nil:
            return .failure(call.id, "There is no tool called \(call.name).")
        case .mcp?:
            return await mcp(call)
        case .agent(let provider, let spec, let rule)?:
            let ask = ask
            let mode = turn.mode
            let context = AgentToolContext(
                turn: turn,
                consent: { request in
                    switch AgentConsentPolicy.decide(rule, mode: mode) {
                    case .allow: return true
                    case .refuse: return false
                    case .ask: return await ask(spec, request)
                    }
                },
                signal: signal)
            return await provider.run(call, in: context)
        }
    }
}
