#if os(macOS)
import AppKit
#else
import UIKit
import UserNotifications
import os
#endif
import Foundation

/// The little the shared code needs to know about the app it runs in, which the Mac and iOS
/// tell differently.
enum Platform {
    /// Whether the app is the one in front, so that what it shows is in front of the user.
    static var isAppActive: Bool {
        #if os(macOS)
        return NSApp.isActive
        #else
        return UIApplication.shared.applicationState == .active
        #endif
    }

    /// Posted when the app comes to the front.
    static var didBecomeActiveNotification: Notification.Name {
        #if os(macOS)
        return NSApplication.didBecomeActiveNotification
        #else
        return UIApplication.didBecomeActiveNotification
        #endif
    }

    /// Posted as the app quits. iOS mostly suspends apps instead, and then this never comes.
    static var willTerminateNotification: Notification.Name {
        #if os(macOS)
        return NSApplication.willTerminateNotification
        #else
        return UIApplication.willTerminateNotification
        #endif
    }

    /// Shows `count` on the app's icon (the Dock's, on the Mac), or nothing when it's 0.
    static func showBadge(_ count: Int) {
        #if os(macOS)
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        #else
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error { logger.error("Failed to set the badge: \(String(describing: error))") }
        }
        #endif
    }

    #if !os(macOS)
    private nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Platform")
    #endif
}
