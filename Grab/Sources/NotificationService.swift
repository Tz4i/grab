import Foundation
import AppKit
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter. Entirely independent of
/// the download/convert pipeline — a failure or denial here never affects
/// (or is even visible to) the yt-dlp/ffmpeg flow.
enum NotificationService {
    fileprivate static let revealActionID = "REVEAL_IN_FINDER"
    private static let completionCategoryID = "JOB_COMPLETION"
    fileprivate static let fileURLKey = "fileURL"

    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        registerCategories()
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    private static func registerCategories() {
        let reveal = UNNotificationAction(identifier: revealActionID, title: "Reveal in Finder", options: [])
        let category = UNNotificationCategory(
            identifier: completionCategoryID,
            actions: [reveal],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// `revealURL`, when provided, attaches a "Reveal in Finder" action to
    /// the notification (handled by `NotificationDelegate` below).
    static func postCompletion(title: String, body: String, revealURL: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let revealURL {
            content.categoryIdentifier = completionCategoryID
            content.userInfo = [fileURLKey: revealURL.path]
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

/// Handles the "Reveal in Finder" notification action. UNUserNotificationCenterDelegate
/// requires NSObjectProtocol conformance, hence the small dedicated class
/// rather than a free function.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == NotificationService.revealActionID,
           let path = response.notification.request.content.userInfo[NotificationService.fileURLKey] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        completionHandler()
    }

    /// Without this, notifications wouldn't show their banner/action while
    /// Grab is the frontmost app (the default UNUserNotificationCenter
    /// behavior suppresses foreground notifications unless the delegate
    /// opts in via this method).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
