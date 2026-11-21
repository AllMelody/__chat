#if os(macOS)
import AppKit
#endif
import Foundation
import os
import UserNotifications

/// Posts user notifications for mentions and private messages, and routes notification
/// clicks back to the conversation that triggered them.
///
/// Threading: create and use on the main thread (owned by ChatStore). Delegate callbacks
/// from UNUserNotificationCenter are `nonisolated` and hop to the main actor before
/// touching `onSelectItem`.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// Called on the main thread with the sidebar item ID (channel/PM) stored in a clicked
    /// notification, so the app can bring that conversation on screen.
    var onSelectItem: ((UUID) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Notifications")

    override init() {
        super.init()
        center.delegate = self
        // On iOS the app icon's badge counts what's waiting, as the Dock's does on the Mac
        // (ChatStore.attentionCount); there, it takes the user's permission.
        #if os(macOS)
        let options: UNAuthorizationOptions = [.alert, .sound]
        #else
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        #endif
        center.requestAuthorization(options: options) { _, error in
            if let error { Self.logger.error("Notification authorization failed: \(String(describing: error))") }
        }
    }

    func post(title: String, subtitle: String, body: String, itemID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.userInfo = ["itemID": itemID.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error { Self.logger.error("Failed to post notification: \(String(describing: error))") }
        }
    }

    /// Show banners even while the app is frontmost — ChatStore already skips posting when
    /// the conversation is the one on screen, so anything that reaches here is for a
    /// conversation the user is not looking at.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let idString = response.notification.request.content.userInfo["itemID"] as? String,
              let itemID = UUID(uuidString: idString) else { return }
        await MainActor.run {
            // On iOS, tapping the notification has already brought the app to the front.
            #if os(macOS)
            NSApp.activate()
            #endif
            onSelectItem?(itemID)
        }
    }
}
