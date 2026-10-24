import SwiftUI

/// Messages sent while a reply runs: queued for the next turn, or sent now as pi and dsh steer.
@Observable
@MainActor
final class ChatQueue {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    /// By chat; in memory only, so a quit drops what was never sent.
    private(set) var items: [UUID: [Item]] = [:]
    /// A message Send Now stopped a reply for, sent once the stop settles.
    @ObservationIgnored private var sendingNow: [UUID: String] = [:]
    @ObservationIgnored private unowned let core: AppCore

    init(core: AppCore) {
        self.core = core
    }

    func queued(in chat: AIChatState) -> [Item] {
        items[chat.session.id] ?? []
    }

    /// Return while a reply runs: the draft waits for the reply to finish.
    func enqueue(_ text: String, in chat: AIChatState) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        items[chat.session.id, default: []].append(Item(text: text))
        return true
    }

    func remove(_ item: Item, in chat: AIChatState) {
        let id = chat.session.id
        items[id]?.removeAll { $0.id == item.id }
        if items[id]?.isEmpty == true { items[id] = nil }
    }

    /// ⌘↵: a native agent reads it at its next step; any other reply is stopped and this one sent.
    @discardableResult
    func sendNow(_ text: String, in chat: AIChatState) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard chat.isStreaming else { return send(text, in: chat) }
        if core.agentCoordinator.steer(text, in: chat) { return true }
        sendingNow[chat.session.id] = text
        core.aiChatCoordinator.stopResponse(in: chat)
        return true
    }

    func sendNow(_ item: Item, in chat: AIChatState) {
        remove(item, in: chat)
        sendNow(item.text, in: chat)
    }

    /// A reply stopped streaming: Send Now goes first, then the queue, but only after a finished reply.
    func replyEnded(in chat: AIChatState) {
        let id = chat.session.id
        let unread = core.agentCoordinator.endSteering(forChat: id)
        if !unread.isEmpty { items[id, default: []].insert(contentsOf: unread.map { Item(text: $0) }, at: 0) }
        if let text = sendingNow.removeValue(forKey: id) {
            _ = send(text, in: chat)
            return
        }
        // A stop or a failure holds the queue, so nothing is sent into a reply that went wrong.
        guard chat.session.messages.last?.state == .complete, let next = items[id]?.first else { return }
        remove(next, in: chat)
        _ = send(next.text, in: chat)
    }

    private func send(_ text: String, in chat: AIChatState) -> Bool {
        core.aiChatCoordinator.sendBindingAgent(text, in: chat)
    }
}

/// The queued messages over a composer: each can be sent now or dropped.
struct ChatQueueStrip: View {
    let chat: AIChatState

    var body: some View {
        let queue = AppCore.shared.chatQueue
        let items = queue.queued(in: chat)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(items) { item in
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .foregroundStyle(Theme.Colors.textTertiary)
                        Text(item.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        Spacer(minLength: Theme.Spacing.sm)
                        Button("Send Now") { queue.sendNow(item, in: chat) }
                            .buttonStyle(.link)
                            .help("Send it to the agent now; ⌘↵ does the same from the field")
                        Button {
                            queue.remove(item, in: chat)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .help("Remove from Queue")
                    }
                    .font(.callout)
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
        }
    }
}

extension View {
    /// The queue moves on whenever this chat's reply stops streaming.
    func drainsChatQueue(_ chat: AIChatState) -> some View {
        onChange(of: chat.isStreaming) { _, streaming in
            if !streaming { AppCore.shared.chatQueue.replyEnded(in: chat) }
        }
    }
}
