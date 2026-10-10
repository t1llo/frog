import AppKit
import ApplicationServices
import FrogCore

/// Geometry is expressed in Accessibility's global, top-left-origin coordinates.
enum WindowGeometry {
    static func displayIndex(for window: CGRect, displays: [CGRect]) -> Int? {
        displays.indices.max { left, right in
            func score(_ index: Int) -> Double {
                let overlap = window.intersection(displays[index])
                if !overlap.isNull { return Double(overlap.width * overlap.height) }
                return -hypot(Double(window.midX - displays[index].midX), Double(window.midY - displays[index].midY))
            }
            return score(left) < score(right)
        }
    }

    static func target(_ action: WindowAction, window: CGRect, displays: [CGRect]) -> CGRect? {
        guard let index = displayIndex(for: window, displays: displays) else { return nil }
        let display = displays[index]
        let halfWidth = display.width / 2, halfHeight = display.height / 2
        switch action {
        case .leftHalf: return CGRect(x: display.minX, y: display.minY, width: halfWidth, height: display.height)
        case .rightHalf: return CGRect(x: display.midX, y: display.minY, width: halfWidth, height: display.height)
        case .topHalf: return CGRect(x: display.minX, y: display.minY, width: display.width, height: halfHeight)
        case .bottomHalf: return CGRect(x: display.minX, y: display.midY, width: display.width, height: halfHeight)
        case .topLeft: return CGRect(x: display.minX, y: display.minY, width: halfWidth, height: halfHeight)
        case .topRight: return CGRect(x: display.midX, y: display.minY, width: halfWidth, height: halfHeight)
        case .bottomLeft: return CGRect(x: display.minX, y: display.midY, width: halfWidth, height: halfHeight)
        case .bottomRight: return CGRect(x: display.midX, y: display.midY, width: halfWidth, height: halfHeight)
        case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds:
            let third = display.width / 3
            let offset: CGFloat = action == .rightThird ? 2 : (action == .centerThird || action == .rightTwoThirds ? 1 : 0)
            let width = (action == .leftTwoThirds || action == .rightTwoThirds) ? third * 2 : third
            return CGRect(x: display.minX + offset * third, y: display.minY, width: width, height: display.height)
        case .centeredSmall, .centeredMedium, .centeredLarge:
            let fraction: CGFloat = action == .centeredSmall ? 0.5 : (action == .centeredMedium ? 0.7 : 0.9)
            let width = display.width * fraction, height = display.height * fraction
            return CGRect(x: display.midX - width / 2, y: display.midY - height / 2, width: width, height: height)
        case .maximize: return display
        case .center:
            let size = CGSize(width: min(window.width, display.width), height: min(window.height, display.height))
            return CGRect(x: display.midX - size.width / 2, y: display.midY - size.height / 2, width: size.width, height: size.height)
        case .nextDisplay, .previousDisplay:
            guard displays.count > 1 else { return window }
            let next = displays[(index + (action == .nextDisplay ? 1 : displays.count - 1)) % displays.count]
            let width = min(window.width, next.width), height = min(window.height, next.height)
            let x = max(0, min(1, (window.minX - display.minX) / max(1, display.width - window.width)))
            let y = max(0, min(1, (window.minY - display.minY) / max(1, display.height - window.height)))
            return CGRect(x: next.minX + x * (next.width - width), y: next.minY + y * (next.height - height), width: width, height: height)
        case .minimize, .restore, .toggleFullScreen: return nil
        }
    }
}

/// AX messaging is kept off the UI thread. Restore state is bounded and device-local.
actor WindowManager {
    private struct PreviousFrame {
        let window: AXUIElement
        let frame: CGRect
    }
    private var previous: [PreviousFrame] = []

    func perform(_ action: WindowAction, pid: pid_t, displays: [CGRect]) throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw FrogError.message("Allow Accessibility in Settings to move windows.") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let window = AXRead.element(app, kAXFocusedWindowAttribute) ?? AXRead.element(app, kAXMainWindowAttribute) else {
            throw FrogError.message("There is no focused window to \(action.title.lowercased()).")
        }
        AXUIElementSetMessagingTimeout(window, 0.2)
        try Task.checkCancellation()
        if action == .minimize {
            try set(window, kAXMinimizedAttribute, kCFBooleanTrue)
            return
        }
        if action == .toggleFullScreen {
            let fullScreen = AXRead.boolean(window, "AXFullScreen") ?? false
            try set(window, "AXFullScreen", fullScreen ? kCFBooleanFalse : kCFBooleanTrue)
            return
        }
        guard AXRead.boolean(window, "AXFullScreen") != true else {
            throw FrogError.message("Exit full screen before moving or resizing this window.")
        }
        guard let current = frame(window), !displays.isEmpty else {
            throw FrogError.message("macOS could not read this window's size or display.")
        }
        let saved = previous.firstIndex { CFEqual($0.window, window) }
        let target: CGRect
        if action == .restore {
            guard let saved else { throw FrogError.message("There is no previous size for this window yet.") }
            let original = previous[saved].frame
            // Keep a restored window reachable after a display has been disconnected.
            if displays.contains(where: { $0.intersects(original) }) { target = original }
            else { target = WindowGeometry.target(.center, window: original, displays: displays) ?? current }
        } else {
            guard let proposed = WindowGeometry.target(action, window: current, displays: displays) else { return }
            target = proposed
        }
        guard target != current else { return }
        var movable = DarwinBoolean(false), resizable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable) == .success, movable.boolValue else {
            throw FrogError.message("This window does not allow its position to be changed.")
        }
        if target.size != current.size {
            guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable) == .success, resizable.boolValue else {
                throw FrogError.message("This window does not allow resizing.")
            }
        }
        try Task.checkCancellation()
        var point = target.origin, size = target.size
        guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else { return }
        // Position first permits moving from a smaller display; repeating it handles app size constraints.
        try set(window, kAXPositionAttribute, position)
        if target.size != current.size { try set(window, kAXSizeAttribute, dimensions) }
        try set(window, kAXPositionAttribute, position)
        if let saved { previous.remove(at: saved) }
        previous.append(PreviousFrame(window: window, frame: current))
        previous = Array(previous.suffix(50))
    }

    private func set(_ window: AXUIElement, _ attribute: String, _ value: CFTypeRef) throws {
        guard AXUIElementSetAttributeValue(window, attribute as CFString, value) == .success else {
            throw FrogError.message("macOS could not apply this window action. The app may not support it.")
        }
    }

    private func frame(_ window: AXUIElement) -> CGRect? {
        guard let rawPoint = AXRead.attribute(window, kAXPositionAttribute), CFGetTypeID(rawPoint) == AXValueGetTypeID(),
              let rawSize = AXRead.attribute(window, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let pointValue = rawPoint as! AXValue, sizeValue = rawSize as! AXValue
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetType(pointValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(pointValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }
}
