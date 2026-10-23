import Foundation

/// A task's checklist: what `update_plan` takes, and the lines an ACP agent's plan shows as too.
enum AgentPlan {
    static let name = "update_plan"
    static let maxSteps = 50
    static let maxStepLength = 300
    static let malformed =
        "update_plan takes a plan: a list of steps, each with step text and a status of pending, "
        + "in_progress or completed."

    enum Status: String, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    struct Item: Equatable, Sendable {
        let step: String
        let status: Status
    }

    /// Codex's own shape, which the models it trained know by heart.
    static func definition(origin: String) -> AITool {
        let status = JSONValue.object([
            "type": .string("string"),
            "enum": .array(["pending", "in_progress", "completed"].map(JSONValue.string))
        ])
        let item = JSONValue.object([
            "type": .string("object"),
            "properties": .object(["step": .object(["type": .string("string")]), "status": status]),
            "required": .array([.string("step"), .string("status")])
        ])
        return AITool(
            name: name,
            description:
                "Keep a checklist for a task of several steps, shown to the user as you go. Send the "
                + "whole list each time, with at most one step in_progress.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["plan": .object(["type": .string("array"), "items": item])]),
                "required": .array([.string("plan")])
            ]),
            origin: origin, title: name)
    }

    /// Nil when there is no step to show; an unknown status reads as pending.
    static func items(in arguments: String) -> [Item]? {
        guard let plan = JSONValue(data: Data(arguments.utf8))?.objectValue?["plan"]?.arrayValue
        else { return nil }
        let items = plan.prefix(maxSteps).compactMap { value -> Item? in
            let object = value.objectValue
            guard let step = object?["step"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                !step.isEmpty
            else { return nil }
            let status = object?["status"]?.stringValue.flatMap(Status.init) ?? .pending
            let line = step.split(whereSeparator: \.isNewline).joined(separator: " ")
            return Item(step: String(line.prefix(maxStepLength)), status: status)
        }
        return items.isEmpty ? nil : items
    }

    static func checklist(_ items: [Item]) -> String {
        let lines = items.map { item in
            switch item.status {
            case .completed: "✓ " + item.step
            case .inProgress: "→ " + item.step
            case .pending: "· " + item.step
            }
        }
        return "Plan:\n" + lines.joined(separator: "\n") + "\n"
    }
}
