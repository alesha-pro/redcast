import Foundation

/// Fork: ↑ in the composer brings back a question to edit; sending it replaces what followed.
struct ChatRecall: Equatable, Sendable {
    let chatID: UUID
    /// What the composer held before, put back by Esc or by stepping past the newest question.
    let draft: String
    private(set) var messageID: UUID
    /// The question as recalled, so arrows step only while it is still unedited.
    private(set) var text: String

    /// The newest question, or the one named; nil when the chat has no such question.
    init?(editing messageID: UUID? = nil, in messages: [ChatMessage], chatID: UUID, draft: String) {
        let questions = Self.questions(in: messages)
        let found = messageID.map { id in questions.first { $0.id == id } } ?? questions.last
        guard let question = found else { return nil }
        self.chatID = chatID
        self.draft = draft
        self.messageID = question.id
        text = question.text
    }

    /// ↑ (-1) to an older question, ↓ (+1) to a newer one; false past the newest ends the recall.
    mutating func step(_ direction: Int, in messages: [ChatMessage]) -> Bool {
        let questions = Self.questions(in: messages)
        guard let index = questions.firstIndex(where: { $0.id == messageID }) else { return false }
        let next = index + direction
        guard next < questions.count else { return false }
        let target = questions[max(next, 0)]
        messageID = target.id
        text = target.text
        return true
    }

    /// Arrows recall only from an empty composer, or over a recalled question left as it was.
    static func arrowsStep(composer: String, recall: ChatRecall?) -> Bool {
        guard let recall else { return composer.isEmpty }
        return composer == recall.text
    }

    /// How many messages stay when `messageID` is sent again: everything before it.
    static func keptCount(editing messageID: UUID, in messages: [ChatMessage]) -> Int? {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
            messages[index].role == .user
        else { return nil }
        return index
    }

    private static func questions(in messages: [ChatMessage]) -> [ChatMessage] {
        messages.filter { $0.role == .user && !$0.text.isEmpty }
    }
}

/// Fork: a branch copies a chat up to one message under new ids, so the two never share a row.
enum ChatBranch {
    static func messages(of messages: [ChatMessage], through messageID: UUID) -> [ChatMessage]? {
        guard let end = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        let kept = messages[...end].filter { $0.state != .streaming }
        guard !kept.isEmpty else { return nil }
        return kept.map { message in
            ChatMessage(
                role: message.role, text: message.text, state: message.state, sentAt: message.sentAt,
                images: message.images, documents: message.documents, searches: message.searches,
                toolUses: message.toolUses, reasoning: message.reasoning, usage: message.usage,
                toolScope: message.toolScope, replay: message.replay)
        }
    }
}

/// Fork: a user message past this many lines folds, with Show more, as Raycast's do.
enum ChatMessageFold {
    static let lineLimit = 10
    /// A line this long wraps at the reading width, so it counts as several.
    static let wrapColumns = 90

    static func folds(_ text: String) -> Bool {
        var lines = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += max(1, (line.count + wrapColumns - 1) / wrapColumns)
            if lines > lineLimit { return true }
        }
        return false
    }
}
