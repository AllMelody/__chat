import AppKit
import UserNotifications

/// Posts macOS user notifications for nick highlights and routes notification clicks
/// back to the conversation that triggered them.
///
/// Threading: create and use on the main thread (owned by ChatStore). Delegate callbacks
/// from UNUserNotificationCenter arrive on an arbitrary queue and hop to main before
/// touching `onSelectNode`.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// Called on the main thread with the node ID (channel/PM) stored in a clicked
    /// notification, so the app can bring that conversation on screen.
    var onSelectNode: ((UUID) -> Void)?

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { print("⚠️ Notification authorization failed: \(error)") }
        }
    }

    func postHighlight(sender: String, text: String, conversation: String, serverName: String, nodeID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "\(sender) mentioned you in \(conversation)"
        content.subtitle = serverName
        content.body = text
        content.sound = .default
        content.userInfo = ["nodeID": nodeID.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error { print("⚠️ Failed to post highlight notification: \(error)") }
        }
    }

    /// Show banners even while the app is frontmost — ChatStore already skips posting when
    /// the mentioning conversation is the one on screen, so anything that reaches here is
    /// for a conversation the user is not looking at.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let idString = response.notification.request.content.userInfo["nodeID"] as? String,
           let nodeID = UUID(uuidString: idString) {
            DispatchQueue.main.async { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.onSelectNode?(nodeID)
            }
        }
        completionHandler()
    }
}
