import ApplicationServices
import FrogCore

/// Invokes macOS's own Apple-menu command without generating another registered hotkey.
actor SystemActionController {
    static let shared = SystemActionController()

    func perform(_ action: SystemAction, pid: pid_t) throws {
        let item = try command(action, pid: pid)
        try Task.checkCancellation()
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            throw FrogError.message("macOS could not lock the screen. Try Lock Screen in the Apple menu.")
        }
    }

    func command(_ action: SystemAction, pid: pid_t) throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw FrogError.message("Allow Accessibility in Settings to use Lock Screen.") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let bar = AXRead.element(app, kAXMenuBarAttribute),
              let apple = (AXRead.attribute(bar, kAXChildrenAttribute) as? [AXUIElement])?.first,
              let menu = (AXRead.attribute(apple, kAXChildrenAttribute) as? [AXUIElement])?.first,
              let items = AXRead.attribute(menu, kAXChildrenAttribute) as? [AXUIElement],
              let item = items.first(where: {
                  // Command is implicit in AX menu modifiers; Control is bit 2.
                  AXRead.string($0, kAXMenuItemCmdCharAttribute)?.lowercased() == "q" &&
                  (AXRead.attribute($0, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 4
              }) else { throw FrogError.message("macOS's Lock Screen command is unavailable in this app. Try another app or the Apple menu.") }
        return item
    }
}
