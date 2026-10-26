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
