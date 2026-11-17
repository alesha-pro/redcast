import Foundation
import UserNotifications

/// Fork: a banner when a chat's reply finishes behind other windows; made only once one is posted.
@MainActor
final class ChatFinishNotifier: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let prefix = "ai-chat-reply-"
    /// Opens the chat a banner names; set by the app, and reached from the agents' notifier too.
    static var openChat: (@MainActor (UUID) -> Void)?

    /// Asked only from Settings' switch, so the system prompt follows the reader's own click.
    static func authorize() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    /// A click on one of these banners, wherever the app's one delegate heard it.
    static func open(identifier: String) -> Bool {
        guard let id = chatID(fromIdentifier: identifier) else { return false }
        openChat?(id)
        return true
    }

    nonisolated static func chatID(fromIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(prefix.count)))
    }

    /// Says a reply is ready, never what it says: a banner is seen by whoever is near the screen.
    func post(chatID: UUID, title: String) {
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = self }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(localized: "The reply is ready.")
        content.threadIdentifier = "ai-chat"
        center.add(UNNotificationRequest(identifier: Self.prefix + chatID.uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        // Read before the hop: the response is not Sendable.
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
            let id = Self.chatID(fromIdentifier: response.notification.request.identifier)
        else { return }
        await MainActor.run { Self.openChat?(id) }
    }
}
