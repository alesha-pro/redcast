import Foundation
import Synchronization

/// What one turn's `web_fetch` may open, shared with its sub-agents; see `admit(_:)`.
nonisolated final class AgentWebScope: Sendable {
    private struct State {
        var messages: [AIMessage] = []
        /// Search results and links on fetched pages that a round has shown the model.
        var shown: [URL] = []
        /// Found since the latest round, shown with the next one.
        var found: [URL] = []
        var personal: Bool
        /// Pages read while narrowed, by key; another part of one is not another read.
        var reads: Set<String> = []
    }

    enum Admission: Equatable, Sendable {
        /// At this address: the one the turn was given, never the model's spelling of it.
        case open(URL)
        case notGiven
        case readsUsed
    }

    /// Nobody sent this turn from its chat: a schedule, the launcher, a voice task.
    let unattended: Bool
    private let state: Mutex<State>
    /// Told the first time the turn reads something personal, so its chat's later turns start narrowed.
    private let onPersonal: @Sendable () -> Void

    /// `personal` carries an earlier turn's reads over: its replies, still in the chat, may hold them.
    init(unattended: Bool, personal: Bool = false, onPersonal: @escaping @Sendable () -> Void = {}) {
        self.unattended = unattended
        self.onPersonal = onPersonal
        state = Mutex(State(personal: personal))
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
        // What the user attached, a screen capture among them, is theirs as their own files are.
        if let messages, messages.contains(where: Self.isAttaching) { notePersonal() }
    }

    /// Search results, and links a fetched part showed on its own site; given once a round shows them.
    func found(_ pages: [URL], on source: URL? = nil) {
        // A link to another site is the easiest way for a page to steer reads, so a search finds it.
        let kept = source.map { source in pages.filter { Self.site(of: $0) == Self.site(of: source) } } ?? pages
        guard !kept.isEmpty else { return }
        state.withLock { $0.found += kept }
    }

    /// The user's files beyond the folder, notes, screen or an attachment reached the model.
    func notePersonal() {
        let first = state.withLock { state in
            defer { state.personal = true }
            return !state.personal
        }
        if first { onPersonal() }
    }

    /// Any page while the user watches and nothing of theirs was read, else only a given one.
    func fetchable(_ asked: URL) -> URL? {
        let (messages, shown, personal) = state.withLock { ($0.messages, $0.shown, $0.personal) }
        let restricted = unattended || personal
        let given = restricted ? WebPageScope.given(in: messages, shown: shown) : [:]
        return WebPageScope.fetchable(asked, given: given, restricted: restricted)
    }

    /// `fetchable`, counting the read: which given pages a narrowed turn reads is itself a signal.
    func admit(_ asked: URL) -> Admission {
        guard let url = fetchable(asked) else { return .notGiven }
        guard isRestricted, let key = WebPageScope.key(for: url) else { return .open(url) }
        return state.withLock { state in
            guard state.reads.contains(key) || state.reads.count < WebPageTool.maxNarrowedReads else {
                return .readsUsed
            }
            state.reads.insert(key)
            return .open(url)
        }
    }

    /// The notes on earlier turns lead the first question, and the model wrote them, not the user.
    private static func withoutNotes(_ message: AIMessage) -> AIMessage {
        guard message.role == .user, message.text.hasPrefix(notesStart),
            let end = message.text.range(of: notesEnd)
        else { return message }
        return AIMessage(
            role: .user, text: String(message.text[end.upperBound...]), images: message.images,
            documents: message.documents, audio: message.audio)
    }

    /// An image, a PDF or an inlined file, as the composer and Ask About Screen attach them.
    private static func isAttaching(_ message: AIMessage) -> Bool {
        message.role == .user
            && (!message.images.isEmpty || !message.documents.isEmpty
                || AIAttachmentPolicy.typed(in: message.text) != message.text)
    }

    /// A host without its `www.`, which is how a page and the links it keeps are told to be one site.
    private static func site(of url: URL) -> String? {
        guard var host = url.host()?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private static let notesStart = "<earlier_conversation>"
    private static let notesEnd = "</earlier_conversation>"
}
