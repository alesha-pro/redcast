import Foundation
import Synchronization

/// What one turn's `web_fetch` may open, shared with its sub-agents; see `fetchable(_:)`.
nonisolated final class AgentWebScope: Sendable {
    private struct State {
        var messages: [AIMessage] = []
        /// Search results and links on fetched pages that a round has shown the model.
        var shown: [URL] = []
        /// Found since the latest round, shown with the next one.
        var found: [URL] = []
        var personal = false
    }

    /// Nobody sent this turn from its chat: a schedule, the launcher, a voice task.
    let unattended: Bool
    private let state = Mutex(State())

    init(unattended: Bool) {
        self.unattended = unattended
    }

    /// The model could have written its own data into an address by now, so only given ones open.
    var isRestricted: Bool { unattended || state.withLock(\.personal) }

    /// A round of the turn's loop or a sub-agent's; a request with no tools, as a summary, is not.
    func note(_ request: AIRequest, readingMessages: Bool = true) {
        guard !request.tools.isEmpty else { return }
        let messages = readingMessages ? request.messages.map(Self.withoutNotes) : nil
        state.withLock {
            if let messages { $0.messages = messages }
            $0.shown += $0.found
            $0.found.removeAll()
        }
    }

    /// Search results, and the links a fetched part showed; given once the next round shows them.
    func found(_ pages: [URL]) {
        guard !pages.isEmpty else { return }
        state.withLock { $0.found += pages }
    }

    /// The user's files beyond the folder, their notes or their screen reached the model.
    func notePersonal() {
        state.withLock { $0.personal = true }
    }

    /// Any page while the user watches and nothing of theirs was read, else only a given one.
    func fetchable(_ asked: URL) -> URL? {
        let (messages, shown, personal) = state.withLock { ($0.messages, $0.shown, $0.personal) }
        let restricted = unattended || personal
        let given = restricted ? WebPageScope.given(in: messages, shown: shown) : [:]
        return WebPageScope.fetchable(asked, given: given, restricted: restricted)
    }

    /// The notes on earlier turns lead the first question, and the model wrote them, not the user.
    private static func withoutNotes(_ message: AIMessage) -> AIMessage {
        guard message.role == .user, message.text.hasPrefix(notesStart),
            let end = message.text.range(of: notesEnd)
        else { return message }
        return AIMessage(role: .user, text: String(message.text[end.upperBound...]))
    }

    private static let notesStart = "<earlier_conversation>"
    private static let notesEnd = "</earlier_conversation>"
}
