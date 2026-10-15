import AppKit
import FrogCore

/// The connected displays, in the order window actions walk them.
enum WindowDisplays {
    @MainActor
    static func current() -> [WindowDisplay] {
        let screens = NSScreen.screens
        let primaryTop = screens.first?.frame.maxY ?? 0
        return WindowDisplay.ordered(screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let uuid = number.flatMap { CGDisplayCreateUUIDFromDisplayID($0.uint32Value)?.takeRetainedValue() }
            let id = uuid.flatMap { CFUUIDCreateString(nil, $0) as String? } ?? screen.localizedName
            return WindowDisplay(id: id, name: screen.localizedName,
                                 frame: accessibilityRect(screen.frame, primaryTop: primaryTop),
                                 visibleFrame: accessibilityRect(screen.visibleFrame, primaryTop: primaryTop))
        })
    }

    /// A Cocoa rectangle (origin bottom left of the primary display) in Accessibility's
    /// coordinates (origin top left), given the top edge of the primary display.
    static func accessibilityRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
}
