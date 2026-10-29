import Foundation
import UserNotifications

enum DesktopNotifications {
    private static let clearedKey = "ClearedEarlyNotifications"

    /// Runs once: later launches keep what plugins scheduled.
    static func clearPreviousNotifications(defaults: UserDefaults = .standard) {
        guard Bundle.main.bundleIdentifier != nil, !defaults.bool(forKey: clearedKey) else { return }
        defaults.set(true, forKey: clearedKey)
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}

/// The one delegate of Frog's notification center. Plugins and Phone each register for the
/// notifications whose `userInfo` carries their key, so neither takes the other's clicks.
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Notifications need the bundled app; `swift run` and tests have no bundle identifier.
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    typealias Handler = @MainActor (_ action: String, _ info: [String: String]) -> Void
    private var handlers: [String: Handler] = [:]
    private var categories: [String: UNNotificationCategory] = [:]

    func register(key: String, category: UNNotificationCategory? = nil, handler: @escaping Handler) {
        handlers[key] = handler
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        if let category, categories[category.identifier] == nil {
            categories[category.identifier] = category
            center.setNotificationCategories(Set(categories.values))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        var info: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        let received = info
        await MainActor.run {
            for key in received.keys { self.handlers[key]?(action, received) }
        }
    }
}
