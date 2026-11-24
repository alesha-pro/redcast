import Foundation

/// `show_text`: exact text the user will copy, handed to whatever surface shows it.
struct LiveVoiceCardTools: LiveVoiceToolSource {
    let present: @MainActor (_ title: String, _ text: String) -> Void

    static let origin = "Live Voice"

    var tools: [AITool] {
        [
            AITool(
                name: LiveVoiceToolName.show,
                description: "Put exact text in front of the user so they can read and copy it: a command, "
                    + "code, a path, a link, a list or a draft. Markdown is rendered.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object([
                            "type": .string("string"), "description": .string("A few words naming the text."),
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("The text itself, as Markdown; code in a fenced block."),
                        ]),
                    ]),
                    "required": .array([.string("text")]),
                ]),
                origin: Self.origin)
        ]
    }

    func run(_ call: AIToolCall, in context: LiveVoiceToolContext) async -> LiveVoiceToolOutcome {
        let arguments = call.liveVoiceArguments
        guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
            return LiveVoiceToolOutcome(.failure(call.id, "show_text needs the text to show."))
        }
        present(arguments["title"]?.stringValue ?? "", text)
        return LiveVoiceToolOutcome(
            AIToolResult(callID: call.id, content: "Shown on screen. Do not read it aloud.", isError: false))
    }
}

/// `start_task`: answers at once and announces the work's result whenever it ends.
struct LiveVoiceTaskTools: LiveVoiceToolSource {
    /// Synchronous start verdict so concurrency or busy refusals return before saying "Started."
    enum Launch {
        case started(@MainActor () async -> String)
        case refused(String)
    }

    let launch: @MainActor (_ task: String) -> Launch

    init(launch: @escaping @MainActor (_ task: String) -> Launch) {
        self.launch = launch
    }

    init(work: @escaping @MainActor (_ task: String) async -> String) {
        launch = { task in .started { await work(task) } }
    }

    var tools: [AITool] {
        [
            AITool(
                name: LiveVoiceToolName.task,
                description: "Hand a longer piece of work to a background agent and return at once. "
                    + "Its result arrives later as a note.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "task": .object([
                            "type": .string("string"),
                            "description": .string(
                                "The whole task in full sentences, with every detail the agent needs; "
                                    + "it has not heard this conversation."),
                        ])
                    ]),
                    "required": .array([.string("task")]),
                ]),
                origin: LiveVoiceCardTools.origin)
        ]
    }

    func run(_ call: AIToolCall, in context: LiveVoiceToolContext) async -> LiveVoiceToolOutcome {
        guard let task = call.liveVoiceArguments["task"]?.stringValue, !task.isEmpty else {
            return LiveVoiceToolOutcome(.failure(call.id, "start_task needs the task."))
        }
        switch launch(task) {
        case .refused(let reason):
            return LiveVoiceToolOutcome(.failure(call.id, reason))
        case .started(let wait):
            let announce = context.announce
            let waiter = Task { @MainActor in
                let result = await wait()
                guard !Task.isCancelled else { return }
                announce("Background task finished.\nTask: \(task)\nResult:\n\(result)")
            }
            context.track(waiter)
            return LiveVoiceToolOutcome(
                AIToolResult(
                    callID: call.id, content: "Started. The result will arrive later as a note.",
                    isError: false))
        }
    }
}
