import Foundation
import UserNotifications
import AppKit

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationManager()

    private let cooldown: TimeInterval = 5 * 60
    private var lastNotified: [String: Date] = [:]

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("NotificationManager: authorization error: \(error)")
            } else {
                print("NotificationManager: authorization granted = \(granted)")
            }
        }
    }

    private func registerCategories() {
        let quitAction = UNNotificationAction(identifier: "QUIT_APP", title: "Quit App", options: [.destructive])
        let category = UNNotificationCategory(identifier: "PERF_ALERT", actions: [quitAction],
                                               intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func notifyIfNeeded(metricKey: String, title: String, body: String, offendingPID: Int32? = nil) {
        let now = Date()
        if let last = lastNotified[metricKey], now.timeIntervalSince(last) < cooldown {
            return
        }
        lastNotified[metricKey] = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let offendingPID {
            content.categoryIdentifier = "PERF_ALERT"
            // Stored as Int rather than Int32: NSNumber bridging through an
            // Any-typed userInfo dictionary reliably supports `as? Int` but
            // isn't guaranteed to bridge fixed-width types like Int32 the
            // same way, which would make the cast on read silently fail.
            content.userInfo = ["pid": Int(offendingPID)]
        }

        let request = UNNotificationRequest(identifier: "\(metricKey)-\(now.timeIntervalSince1970)",
                                             content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("NotificationManager: failed to schedule: \(error)")
            }
        }
    }

    func resetCooldown(metricKey: String) {
        lastNotified[metricKey] = nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             didReceive response: UNNotificationResponse,
                                             withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "QUIT_APP",
           let pid = response.notification.request.content.userInfo["pid"] as? Int {
            NSRunningApplication(processIdentifier: pid_t(pid))?.terminate()
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification,
                                             withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
