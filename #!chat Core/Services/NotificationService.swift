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
/// touching `onSelectConversation`.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// Called on the main thread with the server and the conversation a clicked notification
    /// is about, so the app can bring that conversation on screen. They're named rather than
    /// given by their sidebar ids, which last only as long as the app runs: a notification can
    /// outlive it.
    var onSelectConversation: ((_ serverID: UUID, _ conversation: String) -> Void)?

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

    func post(title: String, subtitle: String, body: String, serverID: UUID, conversation: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.userInfo = ["serverID": serverID.uuidString, "conversation": conversation]
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

    /// The completion handler has to be called on the main thread: on iOS, UIKit asserts that
    /// it is, and calling it from anywhere else ends the app. The async form of this method
    /// can't promise that, as it returns, and so calls it, on the thread it ran on, which for
    /// a nonisolated method isn't the main one. So this takes it, whichever thread it's called
    /// on, and calls it from the main actor. The SDK doesn't mark it @Sendable; it's called
    /// once, from there.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let serverID = (userInfo["serverID"] as? String).flatMap(UUID.init(uuidString:))
        let conversation = userInfo["conversation"] as? String
        Task { @MainActor in
            if let serverID, let conversation {
                // On iOS, tapping the notification has already brought the app to the front.
                #if os(macOS)
                NSApp.activate()
                #endif
                onSelectConversation?(serverID, conversation)
            }
            completionHandler()
        }
    }
}
