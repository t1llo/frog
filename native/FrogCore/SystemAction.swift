import Foundation

public enum SystemAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case lockScreen
    case openHome, openDesktop, openDocuments, openDownloads, openApplications, openUtilities, openLibrary
    case systemSettings, wifiSettings, bluetoothSettings, displaySettings, soundSettings
    case keyboardSettings, trackpadSettings, accessibilitySettings, privacySettings, notificationSettings, storageSettings
    case screenshot, hideApplication, undo, redo, cut, copy, paste, selectAll, find

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .lockScreen: "Lock Screen"
        case .openHome: "Open Home"
        case .openDesktop: "Open Desktop"
        case .openDocuments: "Open Documents"
        case .openDownloads: "Open Downloads"
        case .openApplications: "Open Applications"
        case .openUtilities: "Open Utilities"
        case .openLibrary: "Open Library"
        case .systemSettings: "Open System Settings"
        case .wifiSettings: "Wi-Fi settings"
        case .bluetoothSettings: "Bluetooth settings"
        case .displaySettings: "Display settings"
        case .soundSettings: "Sound settings"
        case .keyboardSettings: "Keyboard settings"
        case .trackpadSettings: "Trackpad settings"
        case .accessibilitySettings: "Accessibility settings"
        case .privacySettings: "Privacy & Security settings"
        case .notificationSettings: "Notification settings"
        case .storageSettings: "Storage settings"
        case .screenshot: "Screenshot controls"
        case .hideApplication: "Hide current app"
        case .undo: "Undo"
        case .redo: "Redo"
        case .cut: "Cut"
        case .copy: "Copy"
        case .paste: "Paste"
        case .selectAll: "Select all"
        case .find: "Find in current app"
        }
    }
    public var detail: String {
        switch self {
        case .openHome, .openDesktop, .openDocuments, .openDownloads, .openApplications, .openUtilities, .openLibrary:
            "Open folder in Finder"
        case .systemSettings, .wifiSettings, .bluetoothSettings, .displaySettings, .soundSettings,
             .keyboardSettings, .trackpadSettings, .accessibilitySettings, .privacySettings, .notificationSettings, .storageSettings:
            "Open macOS settings"
        case .screenshot: "Choose an area, window, or screen to capture"
        case .lockScreen: "Lock this Mac using the Apple menu"
        case .hideApplication: "Hide the frontmost app without quitting"
        case .undo, .redo, .cut, .copy, .paste, .selectAll, .find: "Use the current app’s menu command when available"
        }
    }
    public var symbol: String {
        switch self {
        case .lockScreen: "lock.fill"
        case .openHome: "house"
        case .openDesktop: "desktopcomputer"
        case .openDocuments: "doc.text"
        case .openDownloads: "arrow.down.to.line"
        case .openApplications: "square.grid.2x2"
        case .openUtilities: "wrench.and.screwdriver"
        case .openLibrary: "folder"
        case .systemSettings, .storageSettings: "gearshape"
        case .wifiSettings: "wifi"
        case .bluetoothSettings: "antenna.radiowaves.left.and.right"
        case .displaySettings: "display"
        case .soundSettings: "speaker.wave.2"
        case .keyboardSettings: "keyboard"
        case .trackpadSettings: "rectangle.and.hand.point.up.left"
        case .accessibilitySettings: "accessibility"
        case .privacySettings: "hand.raised"
        case .notificationSettings: "bell"
        case .screenshot: "camera.viewfinder"
        case .hideApplication: "eye.slash"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .cut: "scissors"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .selectAll: "selection.pin.in.out"
        case .find: "magnifyingglass"
        }
    }

    // Persisted identities must not depend on presentation order or future insertions.
    private var ruleNumber: Int {
        switch self {
        case .lockScreen: 1
        case .openHome: 2
        case .openDesktop: 3
        case .openDocuments: 4
        case .openDownloads: 5
        case .openApplications: 6
        case .openUtilities: 7
        case .openLibrary: 8
        case .systemSettings: 9
        case .wifiSettings: 10
        case .bluetoothSettings: 11
        case .displaySettings: 12
        case .soundSettings: 13
        case .keyboardSettings: 14
        case .trackpadSettings: 15
        case .accessibilitySettings: 16
        case .privacySettings: 17
        case .notificationSettings: 18
        case .storageSettings: 19
        case .screenshot: 20
        case .hideApplication: 21
        case .undo: 22
        case .redo: 23
        case .cut: 24
        case .copy: 25
        case .paste: 26
        case .selectAll: 27
        case .find: 28
        }
    }
    public var rule: Rule {
        let id = UUID(uuidString: String(format: "AC57F600-63D0-4E76-9901-%012d", ruleNumber))!
        var rule = Rule(id: id, name: title, instructions: "", enabled: false)
        rule.action = RuleAction(category: .system); rule.action?.systemAction = self
        return rule
    }
}
