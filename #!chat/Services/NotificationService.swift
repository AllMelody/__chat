import AppKit
import os
import UserNotifications

/// Posts macOS user notifications for nick highlights and routes notification clicks
/// back to the conversation that triggered them.
///
/// Threading: create and use on the main thread (owned by ChatStore). Delegate callbacks
/// from UNUserNotificationCenter are `nonisolated` and hop to the main actor before
/// touching `onSelectNode`.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// Called on the main thread with the node ID (channel/PM) stored in a clicked
    /// notification, so the app can bring that conversation on screen.
    var onSelectNode: ((UUID) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Notifications")

    override init() {
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { Self.logger.error("Notification authorization failed: \(String(describing: error))") }
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
            if let error { Self.logger.error("Failed to post highlight notification: \(String(describing: error))") }
        }
    }

    /// Show banners even while the app is frontmost — ChatStore already skips posting when
    /// the mentioning conversation is the one on screen, so anything that reaches here is
    /// for a conversation the user is not looking at.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let idString = response.notification.request.content.userInfo["nodeID"] as? String,
              let nodeID = UUID(uuidString: idString) else { return }
        await MainActor.run {
            NSApp.activate()
            onSelectNode?(nodeID)
        }
    }
}
