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

    /// The frame an action gives a window, inside the usable area of the display that holds
    /// most of it. `step` picks the size of a cycled half from `WindowSizeCycle.fractions`.
    static func target(_ action: WindowAction, window: CGRect, displays: [CGRect],
                       options: WindowLayoutOptions = .legacy, step: Int = 0) -> CGRect? {
        guard let index = displayIndex(for: window, displays: displays) else { return nil }
        let area = options.usableArea(displays[index])
        let halfWidth = area.width / 2, halfHeight = area.height / 2
        let share = WindowSizeCycle.fractions[min(max(0, step), WindowSizeCycle.fractions.count - 1)]
        let tile: CGRect
        switch action {
        case .leftHalf: tile = CGRect(x: area.minX, y: area.minY, width: area.width * share, height: area.height)
        case .rightHalf: tile = CGRect(x: area.minX + area.width * (1 - share), y: area.minY, width: area.width * share, height: area.height)
        case .topHalf: tile = CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height * share)
        case .bottomHalf: tile = CGRect(x: area.minX, y: area.minY + area.height * (1 - share), width: area.width, height: area.height * share)
        case .topLeft: tile = CGRect(x: area.minX, y: area.minY, width: halfWidth, height: halfHeight)
        case .topRight: tile = CGRect(x: area.midX, y: area.minY, width: halfWidth, height: halfHeight)
        case .bottomLeft: tile = CGRect(x: area.minX, y: area.midY, width: halfWidth, height: halfHeight)
        case .bottomRight: tile = CGRect(x: area.midX, y: area.midY, width: halfWidth, height: halfHeight)
        case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds:
            let offset: CGFloat = action == .rightThird ? 2 : (action == .centerThird || action == .rightTwoThirds ? 1 : 0)
            let span: CGFloat = (action == .leftTwoThirds || action == .rightTwoThirds) ? 2 : 1
            // On a display taller than wide, left becomes top and right becomes bottom.
            if options.portraitThirds && area.height > area.width {
                let third = area.height / 3
                tile = CGRect(x: area.minX, y: area.minY + offset * third, width: area.width, height: third * span)
            } else {
                let third = area.width / 3
                tile = CGRect(x: area.minX + offset * third, y: area.minY, width: third * span, height: area.height)
            }
        case .centeredSmall, .centeredMedium, .centeredLarge:
            let fraction: CGFloat = action == .centeredSmall ? 0.5 : (action == .centeredMedium ? 0.7 : 0.9)
            let width = area.width * fraction, height = area.height * fraction
            return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        case .maximize: tile = area
        case .center:
            let size = CGSize(width: min(window.width, area.width), height: min(window.height, area.height))
            return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        case .nextDisplay, .previousDisplay:
            guard displays.count > 1 else { return window }
            let next = options.usableArea(displays[(index + (action == .nextDisplay ? 1 : displays.count - 1)) % displays.count])
            let width = min(window.width, next.width), height = min(window.height, next.height)
            let x = max(0, min(1, (window.minX - area.minX) / max(1, area.width - window.width)))
            let y = max(0, min(1, (window.minY - area.minY) / max(1, area.height - window.height)))
            return CGRect(x: next.minX + x * (next.width - width), y: next.minY + y * (next.height - height), width: width, height: height)
        case .minimize, .restore, .toggleFullScreen: return nil
        }
        return options.spaced(tile, in: area)
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

    /// Where an action would put the focused window of `pid`; for Restore, the frame it would
    /// return to. Reads the window once and writes nothing. Nil when there is nothing to show.
    func preview(_ action: WindowAction, pid: pid_t, displays: [WindowDisplay], options: WindowLayoutOptions = .legacy) -> CGRect? {
        guard access.isTrusted(), let window = access.focusedWindow(pid: pid), !access.state(of: window).fullScreen,
              let current = access.frame(of: window) else { return nil }
        let displays = displays.map(\.visibleFrame)
        guard !displays.isEmpty else { return nil }
        guard action == .restore else { return WindowGeometry.target(action, window: current, displays: displays, options: options) }
        guard let original = history.entry(for: window.key)?.frame else { return nil }
        if displays.contains(where: { $0.intersects(original) }) { return original }
        return WindowGeometry.target(.center, window: original, displays: displays, options: options)
    }

    func perform(_ action: WindowAction, pid: pid_t, displays: [WindowDisplay], options: WindowLayoutOptions = .legacy) throws {
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
        // The size a cycled half has reached.
        var step = 0
        if action == .restore {
            guard let saved else { throw FrogError.message("There is no previous size for this window yet.") }
            let original = saved.frame
            // Keep a restored window reachable after a display has been disconnected.
            if displays.contains(where: { $0.intersects(original) }) { target = original }
            else { target = WindowGeometry.target(.center, window: original, displays: displays, options: options) ?? current }
        } else {
            // A half pressed again on a window still where the last press put it takes the next size.
            if options.cycleSizes, WindowSizeCycle.cycles(action), let saved, saved.action == action,
               let last = WindowGeometry.target(action, window: current, displays: displays, options: options, step: saved.step),
               saved.move.isRepeated(by: last, from: current) {
                step = WindowSizeCycle.next(after: saved.step)
                before = saved.frame
            }
            guard let proposed = WindowGeometry.target(action, window: current, displays: displays, options: options, step: step) else { return }
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
        history.record(window.key, before: before, move: .init(target: target, applied: access.frame(of: window) ?? target),
                       action: action, step: step)
    }
}
