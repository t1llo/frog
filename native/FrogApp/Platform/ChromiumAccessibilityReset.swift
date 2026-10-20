import AppKit
import ApplicationServices
import FrogCore

/// Frog 1.0.31 to 1.0.33 switched Chrome, Electron and other Chromium apps to the accessibility mode a screen reader
/// uses, so the selection bubble could read their text. Such an app then keeps its whole accessibility tree up to date
/// and stays slower until it quits. Once after the update, Frog switches the apps still running back, unless
/// VoiceOver is on and uses that mode. Editors built on VS Code were never switched, so they are left as they are.
@MainActor enum ChromiumAccessibilityReset {
    static let doneKey = "chromiumAccessibilityResetDone"

    static func runOnce(defaults: UserDefaults = .standard) {
        // Without Accessibility no earlier Frog could have switched an app either; it is tried again next launch.
        guard !defaults.bool(forKey: doneKey), AXIsProcessTrusted() else { return }
        defaults.set(true, forKey: doneKey)
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return }
        let system = SelectionWatcher.System.live
        let pids = NSWorkspace.shared.runningApplications.compactMap { app -> pid_t? in
            guard app.activationPolicy == .regular, let url = app.bundleURL, system.builtOnChromium(url),
                  SelectionBubblePolicy.offersWithoutText(bundleID: app.bundleIdentifier, builtOnVSCode: system.builtOnVSCode(url))
            else { return nil }
            return app.processIdentifier
        }
        // Each request waits for its app, so none of them runs on the main thread.
        DispatchQueue.global(qos: .utility).async {
            for pid in pids {
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, 0.25)
                for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
                    _ = AXUIElementSetAttributeValue(application, attribute as CFString, kCFBooleanFalse)
                }
            }
        }
    }
}
