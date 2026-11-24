import Foundation

/// A family of tools the live model may call: the screen, an MCP server, an agent's tasks.
@MainActor
protocol LiveVoiceToolSource {
    var tools: [AITool] { get }
    func run(_ call: AIToolCall, in context: LiveVoiceToolContext) async -> LiveVoiceToolOutcome
}

/// What a call may reach in the session that made it.
struct LiveVoiceToolContext: Sendable {
    /// Puts a note into the conversation later, as a finished background task does.
    let announce: @MainActor @Sendable (String) -> Void
}

struct LiveVoiceToolOutcome: Sendable {
    var result: AIToolResult
    /// A picture the model should see with the result, as a screenshot.
    var image: LiveVoiceImage?

    init(_ result: AIToolResult, image: LiveVoiceImage? = nil) {
        self.result = result
        self.image = image
    }
}

/// Tools that are a list and one closure, which is all an MCP coordinator needs to join.
struct LiveVoiceToolList: LiveVoiceToolSource {
    let tools: [AITool]
    let invoke: @MainActor (AIToolCall) async -> AIToolResult

    func run(_ call: AIToolCall, in context: LiveVoiceToolContext) async -> LiveVoiceToolOutcome {
        LiveVoiceToolOutcome(await invoke(call))
    }
}

/// Every source a session was given; a call goes to the first one that offers its name.
@MainActor
struct LiveVoiceToolbox {
    let sources: [any LiveVoiceToolSource]

    var tools: [AITool] {
        var seen = Set<String>()
        return sources.flatMap(\.tools).filter { seen.insert($0.name).inserted }
    }

    func run(_ call: AIToolCall, in context: LiveVoiceToolContext) async -> LiveVoiceToolOutcome {
        guard let source = sources.first(where: { $0.tools.contains { $0.name == call.name } }) else {
            return LiveVoiceToolOutcome(.failure(call.id, "There is no tool called \(call.name)."))
        }
        return await source.run(call, in: context)
    }
}

extension AIToolCall {
    /// The call's arguments as an object; a model that sent none, or broken JSON, gets an empty one.
    var liveVoiceArguments: [String: JSONValue] {
        JSONValue(data: Data(arguments.utf8))?.objectValue ?? [:]
    }
}
