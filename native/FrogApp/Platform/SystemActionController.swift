import AppKit
import ApplicationServices
import FrogCore

/// Opens native destinations or presses app-provided menu commands, never synthetic hotkeys.
actor SystemActionController {
    static let shared = SystemActionController()

    func perform(_ action: SystemAction, pid: pid_t) throws {
        try Task.checkCancellation()
        if let url = Self.destination(for: action) {
            guard NSWorkspace.shared.open(url) else {
                throw FrogError.message("macOS could not open \(action.title).")
            }
            return
        }
        let item = try command(action, pid: pid)
        try Task.checkCancellation()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard AXRead.boolean(app, kAXFrontmostAttribute) == true else {
            throw FrogError.message("The active app changed. Try \(action.title) again.")
        }
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            throw FrogError.message("macOS could not perform \(action.title). Try the command in the app’s menu.")
        }
    }

    nonisolated static func destination(for action: SystemAction) -> URL? {
        let files = FileManager.default
        switch action {
        case .openHome: return files.homeDirectoryForCurrentUser
        case .openDesktop: return files.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .openDocuments: return files.urls(for: .documentDirectory, in: .userDomainMask).first
        case .openDownloads: return files.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .openApplications: return files.urls(for: .applicationDirectory, in: .localDomainMask).first
        case .openUtilities: return URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)
        case .openLibrary: return files.urls(for: .libraryDirectory, in: .userDomainMask).first
        case .systemSettings: return URL(string: "x-apple.systempreferences:")
        case .wifiSettings: return settings("com.apple.wifi-settings-extension")
        case .bluetoothSettings: return settings("com.apple.BluetoothSettings")
        case .displaySettings: return settings("com.apple.Displays-Settings.extension")
        case .soundSettings: return settings("com.apple.Sound-Settings.extension")
        case .keyboardSettings: return settings("com.apple.Keyboard-Settings.extension")
        case .trackpadSettings: return settings("com.apple.Trackpad-Settings.extension")
        case .accessibilitySettings: return settings("com.apple.Accessibility-Settings.extension")
        case .privacySettings: return settings("com.apple.settings.PrivacySecurity.extension")
        case .notificationSettings: return settings("com.apple.Notifications-Settings.extension")
        case .storageSettings: return settings("com.apple.settings.Storage")
        case .screenshot: return URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app", isDirectory: true)
        case .lockScreen, .hideApplication, .undo, .redo, .cut, .copy, .paste, .selectAll, .find: return nil
        }
    }

    private nonisolated static func settings(_ pane: String) -> URL? {
        URL(string: "x-apple.systempreferences:" + pane)
    }

    struct MenuShortcut: Equatable {
        let character: String
        // Command is implicit; Shift = 1, Option = 2, Control = 4, No Command = 8.
        let modifiers: Int
    }

    nonisolated static func menuShortcut(for action: SystemAction) -> MenuShortcut? {
        switch action {
        case .lockScreen: MenuShortcut(character: "q", modifiers: 4)
        case .hideApplication: MenuShortcut(character: "h", modifiers: 0)
        case .undo: MenuShortcut(character: "z", modifiers: 0)
        case .redo: MenuShortcut(character: "z", modifiers: 1)
        case .cut: MenuShortcut(character: "x", modifiers: 0)
        case .copy: MenuShortcut(character: "c", modifiers: 0)
        case .paste: MenuShortcut(character: "v", modifiers: 0)
        case .selectAll: MenuShortcut(character: "a", modifiers: 0)
        case .find: MenuShortcut(character: "f", modifiers: 0)
        default: nil
        }
    }

    func command(_ action: SystemAction, pid: pid_t) throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw FrogError.message("Allow Accessibility in Settings to use \(action.title).") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard AXRead.boolean(app, kAXFrontmostAttribute) == true,
              let shortcut = Self.menuShortcut(for: action),
              let bar = AXRead.element(app, kAXMenuBarAttribute) else {
            throw unavailable(action)
        }
        let root: AXUIElement
        if action == .lockScreen {
            guard let apple = (AXRead.attribute(bar, kAXChildrenAttribute) as? [AXUIElement])?.first else { throw unavailable(action) }
            root = apple
        } else { root = bar }
        var pending = [(root, 0)]
        var visited = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while let (element, depth) = pending.popLast(), visited < 1_000, ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.15)
            if AXRead.string(element, kAXRoleAttribute) == kAXMenuItemRole,
               AXRead.string(element, kAXMenuItemCmdCharAttribute)?.lowercased() == shortcut.character,
               (AXRead.attribute(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == shortcut.modifiers,
               AXRead.boolean(element, kAXEnabledAttribute) == true {
                return element
            }
            if depth < 6, let children = AXRead.attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                // Visit visible menu order first; bound traversal of unusually large app menus.
                pending.append(contentsOf: children.prefix(1_000 - visited).reversed().map { ($0, depth + 1) })
            }
        }
        throw unavailable(action)
    }

    private func unavailable(_ action: SystemAction) -> FrogError {
        .message("\(action.title) is unavailable in the current app. Check that its menu command is enabled.")
    }
}
