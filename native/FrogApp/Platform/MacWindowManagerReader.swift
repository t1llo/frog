import AppKit
import FrogCore

/// Reads the Desktop & Dock settings that decide where macOS puts windows. Read-only: Frog
/// never changes them.
enum MacWindowManagerReader {
    private static let domain = "com.apple.WindowManager" as CFString
    /// System Settings → Desktop & Dock, where the user changes these settings.
    static let desktopAndDockURL = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!
    /// The older name of the same pane, for a system that does not know the one above.
    static let dockSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.dock")!

    /// Opens Desktop & Dock in System Settings, where the user turns macOS's own tiling off.
    @MainActor
    static func openDesktopAndDock() {
        if !NSWorkspace.shared.open(desktopAndDockURL) { NSWorkspace.shared.open(dockSettingsURL) }
    }

    /// The current values. Stage Manager sends no event when it is switched on or off, so every
    /// window action reads them again; that takes microseconds.
    static func read() -> MacWindowManagerSettings {
        // Drops values this process has cached, so a change made in Control Center counts.
        CFPreferencesAppSynchronize(domain)
        var values: [String: Bool] = [:]
        for key in MacWindowManagerSettings.keys {
            if let number = CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber { values[key] = number.boolValue }
        }
        return MacWindowManagerSettings(values: values, osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}
