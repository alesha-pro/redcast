import Foundation
import Synchronization

/// `delegate`: one read-only sub-agent per call on the turn's own model; its findings are the result.
struct AgentDelegateTools: AgentToolProvider {
    static let name = "delegate"
    /// Under the executor's 28 KB, so the parent's budget never has to cut it.
    static let maxAnswerBytes = 16 * 1_024
    static let maxNameLength = 60
    static let briefing = """
        ## Sub-task

        Another agent handed you the task in the next message. You can only read: you cannot change \
        files, run commands, write notes or ask the user anything, and you do not see that agent's \
        conversation. Work the task through with your tools, then answer with what you found (facts, \
        paths, short quotes) as briefly as the task allows. Your answer goes back to that agent, not to \
        the user.
        """

    /// The parent's route, and the child's read-only toolset and prompt, built with the turn.
    let base: any AIProvider
    let toolset: AgentToolset
    let instructions: String
    /// How many children the parent's run may still start, shared by every call of the run.
    let allowance: AgentSubAgentAllowance
    /// The time and the child's budget, leading its task as a parent's turn is led.
    let opening: String?
    /// An unattended parent's clock: each child hands over before the parent must.
    let clock: AgentRunClock?

    init(
        base: any AIProvider, toolset: AgentToolset, instructions: String,
        allowance: AgentSubAgentAllowance = AgentSubAgentAllowance(AgentEffort.thorough.budget.subAgents),
        opening: String? = nil, clock: AgentRunClock? = nil
    ) {
        self.base = base
        self.toolset = toolset
        self.instructions = instructions
        self.allowance = allowance
        self.opening = opening
        self.clock = clock
    }

    func specs(for turn: AgentTurn) -> [AgentToolSpec] {
        // The call changes nothing itself and never asks, so children of one round run side by side.
        [
            AgentToolSpec(
                tool: Self.definition(origin: turn.profile.name), family: .delegate, risk: .read,
                concurrent: true)
        ]
    }

    func title(for call: AIToolCall) -> String? {
        Self.task(in: call.arguments).map { Self.name + ": " + $0.name }
    }

    func run(_ call: AIToolCall, in context: AgentToolContext) async -> AIToolResult {
        guard let task = Self.task(in: call.arguments) else {
            return .failure(call.id, "delegate takes a name and a task, both non-empty text.")
        }
        guard allowance.take() else {
            return .failure(
                call.id,
                "This run may start no more sub-agents (\(allowance.limit) used). Do the rest of the work yourself.")
        }
        // At its budget or its parent's time the child is asked for its findings once more, tools off.
        let child = AgentLoopProvider(
            base: base, toolset: toolset, budget: .subAgent, outputCap: AgentTurnBudget.outputTokens,
            lead: AgentTurnLead(opening: opening), clock: clock?.child(), answersAnAgent: true)
        let request = AIRequest(
            instructions: instructions, messages: [AIMessage(role: .user, text: task.text)])
        var answer = ""
        var billed = 0.0
        var failure: String?
        do {
            for try await event in child.stream(request) {
                switch event {
                case .text(let delta): answer += delta
                // What it said before its last calls was working aloud, not its answer.
                case .toolCall: answer = ""
                // A running total: each rise is billed now, so a child cut short is still billed.
                case .usage(let usage):
                    if let cost = usage.costUSD, cost > billed {
                        context.signal(.spent(cost - billed))
                        billed = cost
                    }
                default: break
                }
            }
        } catch {
            failure = error.localizedDescription
        }
        let found = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure {
            let partial = found.isEmpty ? "" : " What it had found:\n\n" + Self.bounded(found)
            return .failure(call.id, "The sub-agent stopped: \(failure)" + partial)
        }
        guard !found.isEmpty else { return .failure(call.id, "The sub-agent gave no answer.") }
        return AIToolResult(callID: call.id, content: Self.bounded(found), isError: false)
    }

    static func definition(origin: String) -> AITool {
        AITool(
            name: name,
            description:
                "Hand one self-contained task to a read-only sub-agent with your folder and your "
                + "reading tools. It works on its own and returns only its findings, which keeps long "
                + "searches and reading out of this conversation. Several calls in one reply run at once, "
                + "so split a broad task into independent parts; do not delegate a step you can do in a "
                + "call or two. It cannot change files, run commands or ask the user, and it does not see "
                + "this conversation, so give it everything it needs.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("A few words naming the task, shown to the user.")
                    ]),
                    "task": .object([
                        "type": .string("string"),
                        "description": .string("The whole task, with the context it needs.")
                    ])
                ]),
                "required": .array([.string("name"), .string("task")])
            ]),
            origin: origin, title: name)
    }

    static func task(in arguments: String) -> (name: String, text: String)? {
        let object = JSONValue(data: Data(arguments.utf8))?.objectValue
        guard let text = object?["task"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty,
            let name = object?["name"]?.stringValue?.split(whereSeparator: \.isNewline)
                .joined(separator: " ").trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        else { return nil }
        return (String(name.prefix(maxNameLength)), text)
    }

    /// Whole scalars only, and a cut that says so.
    static func bounded(_ text: String) -> String {
        guard text.utf8.count > maxAnswerBytes else { return text }
        var used = 0
        let kept = text.unicodeScalars.prefix { scalar in
            used += scalar.utf8.count
            return used <= maxAnswerBytes
        }
        return String(kept) + "\n…cut: the sub-agent's answer was longer."
    }
}

/// The sub-agents a run may still start; its delegate calls may run at once, so it locks.
final class AgentSubAgentAllowance: Sendable {
    let limit: Int
    private let used = Mutex(0)

    init(_ limit: Int) {
        self.limit = limit
    }

    /// False once the run's children are spent.
    func take() -> Bool {
        used.withLock { used in
            guard used < limit else { return false }
            used += 1
            return true
        }
    }
}
