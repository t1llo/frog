import AppKit
import ApplicationServices
import FrogCore

/// One window handed out by a `WindowAccess`. Two handles are the same window when their keys are.
struct WindowHandle: @unchecked Sendable, Equatable {
    let key: WindowKey
    /// The live window; nil for windows that only exist in tests.
    let element: AXUIElement?

    static func == (left: WindowHandle, right: WindowHandle) -> Bool { left.key == right.key }
}

struct WindowState: Equatable, Sendable {
    var fullScreen = false
    var minimized = false
    var movable = true
    var resizable = true
}

/// Every read and write window actions make on other apps' windows. Geometry is in
/// Accessibility's global, top-left-origin coordinates.
protocol WindowAccess: Sendable {
    func isTrusted() -> Bool
    /// The app's focused window, else its main window.
    func focusedWindow(pid: pid_t) -> WindowHandle?
    func frame(of window: WindowHandle) -> CGRect?
    func state(of window: WindowHandle) -> WindowState
    /// Writes the position, then the size when `resize` is true, then the position again.
    /// Position first permits moving from a smaller display; repeating it handles app size
    /// constraints.
    func setFrame(_ frame: CGRect, of window: WindowHandle, resize: Bool) throws
    func setMinimized(_ minimized: Bool, of window: WindowHandle) throws
    func setFullScreen(_ fullScreen: Bool, of window: WindowHandle) throws
}

/// Windows of running apps, through Accessibility.
struct AXWindowAccess: WindowAccess {
    private static let timeout: Float = 0.2
    private static let failure = FrogError.message("macOS could not apply this window action. The app may not support it.")
    /// Set by assistive apps. Chromium and Electron apps then animate window changes and settle
    /// at a different size than the one written.
    private static let enhancedInterface = "AXEnhancedUserInterface"

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func focusedWindow(pid: pid_t) -> WindowHandle? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.timeout)
        guard let window = AXRead.element(app, kAXFocusedWindowAttribute) ?? AXRead.element(app, kAXMainWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, Self.timeout)
        return WindowHandle(key: Self.key(of: window, pid: pid), element: window)
    }

    /// The window's number when WindowServer lends it, else the element's hash, which stays
    /// the same for one window across reads and moves.
    static func key(of window: AXUIElement, pid: pid_t) -> WindowKey {
        WindowKey(pid: pid, number: WindowSpaceBridge.windowID(window) ?? UInt32(truncatingIfNeeded: CFHash(window)))
    }

    func frame(of window: WindowHandle) -> CGRect? {
        guard let element = window.element,
              let rawPoint = AXRead.attribute(element, kAXPositionAttribute), CFGetTypeID(rawPoint) == AXValueGetTypeID(),
              let rawSize = AXRead.attribute(element, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let pointValue = rawPoint as! AXValue, sizeValue = rawSize as! AXValue
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetType(pointValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(pointValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    func state(of window: WindowHandle) -> WindowState {
        guard let element = window.element else { return WindowState(movable: false, resizable: false) }
        func settable(_ attribute: String) -> Bool {
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
        }
        return WindowState(fullScreen: AXRead.boolean(element, "AXFullScreen") ?? false,
                           minimized: AXRead.boolean(element, kAXMinimizedAttribute) ?? false,
                           movable: settable(kAXPositionAttribute), resizable: settable(kAXSizeAttribute))
    }

    func setFrame(_ frame: CGRect, of window: WindowHandle, resize: Bool) throws {
        guard let element = window.element else { throw Self.failure }
        var point = frame.origin, size = frame.size
        guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else { throw Self.failure }
        let app = AXUIElementCreateApplication(window.key.pid)
        AXUIElementSetMessagingTimeout(app, Self.timeout)
        let enhanced = AXRead.boolean(app, Self.enhancedInterface) == true
        if enhanced { AXUIElementSetAttributeValue(app, Self.enhancedInterface as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, Self.enhancedInterface as CFString, kCFBooleanTrue) } }
        try set(element, kAXPositionAttribute, position)
        if resize { try set(element, kAXSizeAttribute, dimensions) }
        try set(element, kAXPositionAttribute, position)
    }

    func setMinimized(_ minimized: Bool, of window: WindowHandle) throws {
        guard let element = window.element else { throw Self.failure }
        try set(element, kAXMinimizedAttribute, minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }

    func setFullScreen(_ fullScreen: Bool, of window: WindowHandle) throws {
        guard let element = window.element else { throw Self.failure }
        try set(element, "AXFullScreen", fullScreen ? kCFBooleanTrue : kCFBooleanFalse)
    }

    private func set(_ window: AXUIElement, _ attribute: String, _ value: CFTypeRef) throws {
        guard AXUIElementSetAttributeValue(window, attribute as CFString, value) == .success else { throw Self.failure }
    }
}
