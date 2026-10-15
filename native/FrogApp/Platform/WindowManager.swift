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

    /// Where an action asked a window to go and where its app put it. Targets such as a third
    /// of a display are fractions of a point, and apps round sizes or keep to a minimum, a
    /// maximum or a character grid, so the two differ.
    struct Move: Equatable {
        var target: CGRect
        var applied: CGRect

        /// The same place is asked for again while the window still sits where it was put,
        /// as when a shortcut is pressed twice. That is the same move, not a new one.
        func isRepeated(by target: CGRect, from current: CGRect) -> Bool {
            WindowGeometry.close(target, self.target) && WindowGeometry.close(current, applied)
        }
    }

    /// Within one point on every edge.
    static func close(_ left: CGRect, _ right: CGRect) -> Bool {
        abs(left.minX - right.minX) <= 1 && abs(left.minY - right.minY) <= 1
            && abs(left.width - right.width) <= 1 && abs(left.height - right.height) <= 1
    }
}

/// AX messaging is kept off the UI thread. Restore state is bounded and device-local.
actor WindowManager {
    private let access: WindowAccess
    private var history = WindowFrameHistory()

    init(access: WindowAccess = AXWindowAccess()) {
        self.access = access
    }

    /// What Restore would return the window to, and the action that moved it last.
    func lastMove(of key: WindowKey) -> WindowFrameHistory.Entry? { history.entry(for: key) }

    func perform(_ action: WindowAction, pid: pid_t, displays: [WindowDisplay]) throws {
        try Task.checkCancellation()
        guard access.isTrusted() else { throw FrogError.message("Allow Accessibility in Settings → Permissions to move windows.") }
        guard let window = access.focusedWindow(pid: pid) else {
            throw FrogError.message("There is no focused window to \(action.title.lowercased()).")
        }
        try Task.checkCancellation()
        if action == .minimize {
            try access.setMinimized(true, of: window)
            return
        }
        let state = access.state(of: window)
        if action == .toggleFullScreen {
            try access.setFullScreen(!state.fullScreen, of: window)
            return
        }
        guard !state.fullScreen else {
            throw FrogError.message("Exit full screen before moving or resizing this window.")
        }
        let displays = displays.map(\.visibleFrame)
        guard let current = access.frame(of: window), !displays.isEmpty else {
            throw FrogError.message("macOS could not read this window's size or display.")
        }
        let saved = history.entry(for: window.key)
        let target: CGRect
        // What Restore returns to once this action has moved the window.
        var before = current
        if action == .restore {
            guard let saved else { throw FrogError.message("There is no previous size for this window yet.") }
            let original = saved.frame
            // Keep a restored window reachable after a display has been disconnected.
            if displays.contains(where: { $0.intersects(original) }) { target = original }
            else { target = WindowGeometry.target(.center, window: original, displays: displays) ?? current }
        } else {
            guard let proposed = WindowGeometry.target(action, window: current, displays: displays) else { return }
            // The same shortcut again on a window that could not take the exact frame sets
            // that frame once more. Restore still returns to the frame before the first press.
            if let saved, saved.move.isRepeated(by: proposed, from: current) { before = saved.frame }
            target = proposed
        }
        guard target != current else { return }
        guard state.movable else {
            throw FrogError.message("This window does not allow its position to be changed.")
        }
        let resize = target.size != current.size
        if resize, !state.resizable {
            throw FrogError.message("This window does not allow resizing.")
        }
        try Task.checkCancellation()
        try access.setFrame(target, of: window, resize: resize)
        history.record(window.key, before: before, move: .init(target: target, applied: access.frame(of: window) ?? target))
    }
}
