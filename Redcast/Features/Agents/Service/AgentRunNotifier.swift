import Foundation
import UserNotifications

/// Notification Center banners for finished runs; exists only once some agent opts in.
@MainActor
final class AgentRunNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let category = "agent-run"
    private static let openAction = "open"

    private let onOpen: @MainActor (UUID) -> Void
    /// One delegate per app: a banner another feature posted, by its identifier; true when handled.
    static var foreignResponse: (@MainActor (String) -> Bool)?

    init(onOpen: @escaping @MainActor (UUID) -> Void) {
        self.onOpen = onOpen
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(
            identifier: Self.openAction, title: String(localized: "Open"), options: .foreground)
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [open], intentIdentifiers: [])
        ])
    }

    /// Asked from the editor's toggle, so the system prompt follows the user's own click.
    static func authorize() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    /// Says that a run ended, never what it found: a banner is seen by whoever is near the screen.
    func post(_ run: AgentRun, body: String) {
        let content = UNMutableNotificationContent()
        content.title = run.agentName
        content.subtitle = run.title
        content.body = body
        content.categoryIdentifier = Self.category
        content.threadIdentifier = run.agentID.uuidString
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: run.id.uuidString, content: content, trigger: nil))
    }

    func withdraw(_ runID: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [runID.uuidString])
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
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        let identifier = response.notification.request.identifier
        if await MainActor.run(body: { Self.foreignResponse?(identifier) ?? false }) { return }
        guard
            let id = UUID(uuidString: response.notification.request.identifier)
        else { return }
        await MainActor.run { onOpen(id) }
    }
}
