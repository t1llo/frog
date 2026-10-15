import Foundation

/// The layout a window dragged to a screen edge or corner would take, and on which display.
public struct SnapCandidate: Equatable, Sendable {
    public var action: WindowAction
    public var displayID: String
    /// The edge or corner touches another display, so it counts only after the pointer rests there.
    public var sharedEdge: Bool

    public init(action: WindowAction, displayID: String, sharedEdge: Bool) {
        self.action = action; self.displayID = displayID; self.sharedEdge = sharedEdge
    }
}

/// Which edge or corner zone the pointer is in, measured on the full frame of the display
/// under it, in Accessibility's top-left-origin coordinates.
public enum SnapZoneResolver {
    /// An edge counts while the pointer is this close to it.
    public static let edgeMargin: CGFloat = 5
    /// The side of the square in each corner.
    public static let cornerSize: CGFloat = 20
    /// How long the pointer rests on an edge shared with another display before it counts.
    public static let sharedEdgeDwell: TimeInterval = 0.3

    public static func candidate(at point: CGPoint, displays: [WindowDisplay], edgesPaused: Bool) -> SnapCandidate? {
        guard !edgesPaused, let display = display(at: point, in: displays) else { return nil }
        let frame = display.frame
        let left = point.x - frame.minX, right = frame.maxX - point.x
        let top = point.y - frame.minY, bottom = frame.maxY - point.y
        let others = displays.filter { $0.id != display.id }.map(\.frame)
        func shared(_ edge: Edge) -> Bool { others.contains { touches($0, edge, of: frame, at: point) } }
        func result(_ action: WindowAction, _ edges: Edge...) -> SnapCandidate {
            SnapCandidate(action: action, displayID: display.id, sharedEdge: edges.contains { shared($0) })
        }
        switch (left <= cornerSize, right <= cornerSize, top <= cornerSize, bottom <= cornerSize) {
        case (true, _, true, _): return result(.topLeft, .left, .top)
        case (_, true, true, _): return result(.topRight, .right, .top)
        case (true, _, _, true): return result(.bottomLeft, .left, .bottom)
        case (_, true, _, true): return result(.bottomRight, .right, .bottom)
        default: break
        }
        if left <= edgeMargin { return result(.leftHalf, .left) }
        if right <= edgeMargin { return result(.rightHalf, .right) }
        if top <= edgeMargin { return result(.maximize, .top) }
        if bottom <= edgeMargin {
            let third = frame.width / 3
            let action: WindowAction = left < third ? .leftThird : (left < third * 2 ? .centerThird : .rightThird)
            return result(action, .bottom)
        }
        return nil
    }

    /// How close to an outer edge macOS's own tiling takes over a release.
    public static let nativeBand: CGFloat = 6

    /// macOS tiles a window released here itself, even while Shift is held, so Frog's zones
    /// stay out of it: within 6 pt of a display's left, right or bottom edge while edge tiling
    /// is on, or of its top edge while top-edge tiling is on, unless another display lies
    /// against that edge. While Option tiles and is held, everywhere.
    public static func nativeEdgeBand(at point: CGPoint, displays: [WindowDisplay], macOS: MacWindowManagerSettings,
                                      optionDown: Bool) -> Bool {
        if macOS.optionAccelerator && optionDown { return true }
        guard macOS.edgeTiling || macOS.topEdgeTiling, let display = display(at: point, in: displays) else { return false }
        let frame = display.frame
        let others = displays.filter { $0.id != display.id }.map(\.frame)
        func dead(_ edge: Edge, _ distance: CGFloat) -> Bool {
            distance <= nativeBand && !others.contains { touches($0, edge, of: frame, at: point) }
        }
        if macOS.edgeTiling, dead(.left, point.x - frame.minX) || dead(.right, frame.maxX - point.x)
            || dead(.bottom, frame.maxY - point.y) { return true }
        return macOS.topEdgeTiling && dead(.top, point.y - frame.minY)
    }

    private enum Edge { case left, right, top, bottom }

    /// The display whose frame holds the point; on the far right or bottom edge, where a
    /// rectangle does not hold its own edge, the one within a point of it.
    static func display(at point: CGPoint, in displays: [WindowDisplay]) -> WindowDisplay? {
        displays.first { $0.frame.contains(point) } ?? displays.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    }

    /// Another display's frame lies against this edge, within a point, and spans the pointer's
    /// position along it.
    private static func touches(_ other: CGRect, _ edge: Edge, of frame: CGRect, at point: CGPoint) -> Bool {
        switch edge {
        case .left: abs(other.maxX - frame.minX) <= 1 && other.minY <= point.y && point.y <= other.maxY
        case .right: abs(other.minX - frame.maxX) <= 1 && other.minY <= point.y && point.y <= other.maxY
        case .top: abs(other.maxY - frame.minY) <= 1 && other.minX <= point.x && point.x <= other.maxX
        case .bottom: abs(other.minY - frame.maxY) <= 1 && other.minX <= point.x && point.x <= other.maxX
        }
    }
}

/// One window drag, from the first frame read to the release: whether the window really moves
/// with the pointer, which zone the pointer is in, and when a snapped window gets its earlier
/// size back. While Shift is held, the zone overlay replaces the edges. Pure: the caller reads
/// frames, shows the preview and the overlay, and moves the window.
public struct SnapDragSession: Sendable {
    public enum Effect: Equatable, Sendable {
        /// The window moves with the pointer: this is a window drag.
        case confirmDrag
        case showPreview(SnapCandidate)
        case hidePreview
        /// Give the window this frame now: its size before Frog last moved it, under the pointer.
        case restoreSize(CGRect)
        /// Show the zone overlay on this display, or move it there.
        case showOverlay(displayID: String)
        /// Highlight this zone of the overlay, or none.
        case highlight(WindowAction?)
        case hideOverlay
    }

    /// What the zone overlay works with, kept while Shift is held.
    private struct Overlay {
        var grid: ZoneGrid
        var options: WindowLayoutOptions
        var macOS: MacWindowManagerSettings
        var optionDown: Bool
        /// The display the overlay shows on; nil until it shows.
        var displayID: String?
        var highlight: WindowAction?
    }

    /// A read frame whose origin is this close to where the pointer took it confirms the drag.
    public static let followTolerance: CGFloat = 4
    /// How far the pointer moves a snapped window before it gets its earlier size back.
    public static let restoreDistance: CGFloat = 10

    private let window: CGRect
    private let pointer: CGPoint
    private let edgesPaused: Bool
    /// The size to give back once the drag has gone far enough; nil when the window is not
    /// where Frog last put it.
    private let restoreSize: CGSize?
    /// How far the pointer had moved from the mouse-down when the window was read.
    private let travel: CGFloat
    /// Pointer positions since the last frame was read; that frame was taken at one of them.
    private var path: [CGPoint]
    public private(set) var confirmed = false
    /// The window changed size, or Escape was pressed: this drag snaps nothing.
    public private(set) var finished = false
    private var restored = false
    /// The zone the pointer is in and since when.
    private var zone: (candidate: SnapCandidate, since: TimeInterval)?
    private var shown: SnapCandidate?
    /// Shift is held: the overlay shows once the drag is confirmed.
    private var overlay: Overlay?

    /// - Parameters:
    ///   - window: the dragged window's frame, read while the pointer was at `pointer`.
    ///   - lastMove: the frame Frog last gave this window, and `sizeBeforeMove` its size before.
    ///   - travel: how far the pointer had moved from the mouse-down when the window was read;
    ///     a window still where Frog put it may have followed the pointer that far.
    public init(window: CGRect, pointer: CGPoint, time: TimeInterval, lastMove: CGRect?, sizeBeforeMove: CGSize?,
                restoreOnDrag: Bool, edgesPaused: Bool, travel: CGFloat = 0) {
        self.window = window
        self.pointer = pointer
        self.edgesPaused = edgesPaused
        self.travel = travel
        path = [pointer]
        if restoreOnDrag, let lastMove, let sizeBeforeMove,
           abs(window.width - lastMove.width) <= 1, abs(window.height - lastMove.height) <= 1,
           abs(window.minX - lastMove.minX) <= 1 + travel, abs(window.minY - lastMove.minY) <= 1 + travel,
           abs(sizeBeforeMove.width - window.width) > 1 || abs(sizeBeforeMove.height - window.height) > 1 {
            restoreSize = sizeBeforeMove
        } else {
            restoreSize = nil
        }
    }

    /// The window's frame when the drag was first read.
    public var startFrame: CGRect { window }

    /// When the pointer, resting where it is, makes a shared edge count; nil when nothing waits.
    public var dwellDeadline: TimeInterval? {
        guard confirmed, !finished, overlay == nil, let zone, zone.candidate.sharedEdge, shown != zone.candidate else { return nil }
        return zone.since + SnapZoneResolver.sharedEdgeDwell
    }

    /// The pointer moved, and with `windowFrame` the window's frame was read again.
    public mutating func move(to point: CGPoint, time: TimeInterval, windowFrame: CGRect?, displays: [WindowDisplay]) -> [Effect] {
        guard !finished else { return [] }
        var effects: [Effect] = []
        if !confirmed {
            path.append(point)
            if path.count > 64 { path.removeFirst(path.count - 64) }
            guard let windowFrame else { return [] }
            if abs(windowFrame.width - window.width) > 1 || abs(windowFrame.height - window.height) > 1 {
                finished = true
                return []
            }
            guard follows(windowFrame) else { path = [point]; return [] }
            confirmed = true
            effects.append(.confirmDrag)
        }
        if let restoreSize, !restored, travel + hypot(point.x - pointer.x, point.y - pointer.y) >= Self.restoreDistance {
            restored = true
            // The pointer keeps its place across the width and its distance from the top.
            let share = window.width > 0 ? (pointer.x - window.minX) / window.width : 0.5
            effects.append(.restoreSize(CGRect(x: point.x - share * restoreSize.width, y: point.y - (pointer.y - window.minY),
                                               width: restoreSize.width, height: restoreSize.height)))
        }
        effects += overlay == nil ? track(point, time: time, displays: displays) : trackOverlay(point, displays: displays)
        return effects
    }

    /// Shift went down or up, or Option changed while Shift is held. Down shows the overlay of
    /// `grid` on the display under the pointer once the drag is confirmed; up hides it and goes
    /// back to the edges. `macOS` and `optionDown` decide where macOS tiles by itself.
    public mutating func shiftChanged(_ down: Bool, pointer: CGPoint, time: TimeInterval, displays: [WindowDisplay], grid: ZoneGrid,
                                      options: WindowLayoutOptions, macOS: MacWindowManagerSettings, optionDown: Bool) -> [Effect] {
        guard !finished else { return [] }
        if down {
            overlay = Overlay(grid: grid, options: options, macOS: macOS, optionDown: optionDown,
                              displayID: overlay?.displayID, highlight: overlay?.highlight)
            guard confirmed else { return [] }
            zone = nil
            return trackOverlay(pointer, displays: displays, force: overlay?.displayID == nil)
        }
        guard let previous = overlay else { return [] }
        overlay = nil
        guard confirmed else { return [] }
        var effects: [Effect] = previous.displayID == nil ? [] : [.hideOverlay]
        zone = nil
        effects += track(pointer, time: time, displays: displays)
        return effects
    }

    /// Escape: hides the preview, and the release applies nothing.
    public mutating func cancel() -> [Effect] {
        finished = true
        zone = nil
        var effects: [Effect] = []
        if shown != nil { shown = nil; effects.append(.hidePreview) }
        if overlay?.displayID != nil { effects.append(.hideOverlay) }
        overlay = nil
        return effects
    }

    /// The layout to apply where the button is released, if any.
    /// While the overlay shows, the zone under the pointer, even with the edges paused; nothing
    /// where macOS tiles by itself.
    public func end(at point: CGPoint, time: TimeInterval, displays: [WindowDisplay]) -> SnapCandidate? {
        guard confirmed, !finished else { return nil }
        if let overlay { return Self.overlayZone(at: point, displays: displays, overlay: overlay) }
        guard let candidate = SnapZoneResolver.candidate(at: point, displays: displays, edgesPaused: edgesPaused) else { return nil }
        guard candidate.sharedEdge else { return candidate }
        guard let zone, zone.candidate == candidate, time - zone.since >= SnapZoneResolver.sharedEdgeDwell else { return nil }
        return candidate
    }

    /// The window's origin moved as far as the pointer did, at one of the pointer positions
    /// since the frame was last read.
    private func follows(_ frame: CGRect) -> Bool {
        let dx = frame.minX - window.minX, dy = frame.minY - window.minY
        guard abs(dx) > 1 || abs(dy) > 1 else { return false }
        return path.contains { point in
            abs(point.x - pointer.x - dx) <= Self.followTolerance && abs(point.y - pointer.y - dy) <= Self.followTolerance
        }
    }

    /// The zone of the overlay under the point, on the display under it; the point is kept to
    /// the usable area, so the menu bar and the Dock count as the zone next to them.
    private static func overlayZone(at point: CGPoint, displays: [WindowDisplay], overlay: Overlay) -> SnapCandidate? {
        guard let display = SnapZoneResolver.display(at: point, in: displays),
              !SnapZoneResolver.nativeEdgeBand(at: point, displays: displays, macOS: overlay.macOS, optionDown: overlay.optionDown)
        else { return nil }
        let area = overlay.options.usableArea(display.visibleFrame)
        let portrait = overlay.options.portraitThirds && area.height > area.width
        let inside = CGPoint(x: min(max(point.x, area.minX), area.maxX), y: min(max(point.y, area.minY), area.maxY))
        return overlay.grid.zone(at: inside, in: area, portrait: portrait)
            .map { SnapCandidate(action: $0, displayID: display.id, sharedEdge: false) }
    }

    private mutating func trackOverlay(_ point: CGPoint, displays: [WindowDisplay], force: Bool = false) -> [Effect] {
        guard var overlay else { return [] }
        var effects: [Effect] = []
        let display = SnapZoneResolver.display(at: point, in: displays)
        var moved = force
        if let display, display.id != overlay.displayID {
            overlay.displayID = display.id
            effects.append(.showOverlay(displayID: display.id))
            moved = true
        }
        let candidate = Self.overlayZone(at: point, displays: displays, overlay: overlay)
        if moved || candidate?.action != overlay.highlight {
            overlay.highlight = candidate?.action
            effects.append(.highlight(candidate?.action))
        }
        self.overlay = overlay
        if candidate != shown {
            shown = candidate
            effects.append(candidate.map(Effect.showPreview) ?? .hidePreview)
        }
        return effects
    }

    private mutating func track(_ point: CGPoint, time: TimeInterval, displays: [WindowDisplay]) -> [Effect] {
        let candidate = SnapZoneResolver.candidate(at: point, displays: displays, edgesPaused: edgesPaused)
        if candidate != zone?.candidate { zone = candidate.map { ($0, time) } }
        let visible = zone.flatMap { zone in
            !zone.candidate.sharedEdge || time - zone.since >= SnapZoneResolver.sharedEdgeDwell ? zone.candidate : nil
        }
        guard visible != shown else { return [] }
        shown = visible
        return [visible.map(Effect.showPreview) ?? .hidePreview]
    }
}
