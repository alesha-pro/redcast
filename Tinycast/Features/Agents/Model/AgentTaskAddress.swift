import Foundation

/// `@handle task` typed in root search: which agent it names, and what it asks of it.
enum AgentTaskAddress: Equatable, Sendable {
    /// `@` or `@ri` with no space yet: agents whose handle starts so, in creation order.
    case completing([UUID])
    /// `@rig ` and whatever follows it; an empty task opens a chat instead of running one.
    case task(agent: UUID, text: String)

    /// Lower-cased letters and digits; every other run of characters is one hyphen; never empty.
    static func handle(for name: String) -> String {
        var handle = ""
        var pendingHyphen = false
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingHyphen, !handle.isEmpty { handle.append("-") }
                pendingHyphen = false
                handle.append(character)
            } else {
                pendingHyphen = true
            }
        }
        return handle.isEmpty ? "agent" : handle
    }

    /// One handle per agent, in creation order; a clash takes `-2`, `-3`…
    static func handles(for agents: [AgentProfile]) -> [(id: UUID, handle: String)] {
        var taken: Set<String> = []
        return agents.sorted { $0.createdAt < $1.createdAt }.map { agent in
            let base = handle(for: agent.name)
            var candidate = base
            var suffix = 2
            while taken.contains(candidate) {
                candidate = "\(base)-\(suffix)"
                suffix += 1
            }
            taken.insert(candidate)
            return (agent.id, candidate)
        }
    }

    /// Nil unless the query opens with `@` and names, or starts to name, an agent.
    static func parse(_ query: String, handles: [(id: UUID, handle: String)]) -> AgentTaskAddress? {
        let trimmed = query.drop { $0 == " " }
        guard trimmed.first == "@" else { return nil }
        let afterAt = trimmed.dropFirst()
        let token = afterAt.prefix { !$0.isWhitespace }.lowercased()
        let rest = afterAt.dropFirst(afterAt.prefix { !$0.isWhitespace }.count)
        guard rest.isEmpty else {
            guard let match = handles.first(where: { $0.handle == token }) else { return nil }
            return .task(agent: match.id, text: rest.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let matches = handles.filter { $0.handle.hasPrefix(token) }.map(\.id)
        return matches.isEmpty ? nil : .completing(matches)
    }
}
