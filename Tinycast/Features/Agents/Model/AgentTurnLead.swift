import Foundation

/// What leads a turn's question: the turn's facts, and a reply the last turn could not finish.
struct AgentTurnLead: Equatable, Sendable {
    /// The time and the budget, in the question so the prompt above it stays cached.
    var opening: String?
    /// A reply that failed or was stopped, which history leaves out; it goes back before the question.
    var resuming: String?

    init(opening: String? = nil, resuming: String? = nil) {
        self.opening = opening
        self.resuming = resuming
    }

    func led(_ messages: [AIMessage]) -> [AIMessage] {
        guard var question = messages.lastIndex(where: { $0.role == .user }) else { return messages }
        var messages = messages
        if let resuming, question > 0, messages[question - 1].role == .user {
            messages.insert(AIMessage(role: .assistant, text: resuming), at: question)
            question += 1
        }
        guard let opening else { return messages }
        let asked = messages[question]
        messages[question] = AIMessage(
            role: .user, text: opening + "\n\n" + asked.text, images: asked.images, documents: asked.documents,
            audio: asked.audio)
        return messages
    }
}
