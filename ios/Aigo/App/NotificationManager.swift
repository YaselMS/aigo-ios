import Foundation
import UserNotifications

/// Local notifications for host `notify` events while the app is running or
/// recently backgrounded. (Closed-app alerts are the host's ntfy webhook.)
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// Called on the main actor when the user taps a notification.
    var onOpenSession: (@MainActor (String) -> Void)?

    private static let wanted: Set<String> = [
        "approval_required", "task_complete", "error", "stalled", "idle_reminder",
    ]

    func setup() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ notice: HostNotice, hostName: String) {
        let category = notice.category ?? ""
        guard NotificationManager.wanted.contains(category) else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title?.isEmpty == false ? notice.title! : NotificationManager.fallbackTitle(category)
        content.body = notice.body ?? ""
        if !hostName.isEmpty {
            content.subtitle = hostName
        }
        content.sound = .default
        content.threadIdentifier = notice.sessionId ?? "aigo"
        var info: [String: Any] = ["category": category]
        if let sid = notice.sessionId, !sid.isEmpty {
            info["sessionId"] = sid
        }
        content.userInfo = info
        let id = notice.id?.isEmpty == false ? notice.id! : UUID().uuidString
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private static func fallbackTitle(_ category: String) -> String {
        switch category {
        case "approval_required": return "An agent needs you"
        case "task_complete": return "An agent finished"
        case "error": return "An agent reported an error"
        case "stalled": return "An agent looks stalled"
        case "idle_reminder": return "An agent is waiting"
        default: return "Aigo"
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let sid = response.notification.request.content.userInfo["sessionId"] as? String
        if let sid = sid, !sid.isEmpty {
            Task { @MainActor in
                NotificationManager.shared.onOpenSession?(sid)
            }
        }
        completionHandler()
    }
}
