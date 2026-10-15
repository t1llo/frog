import Foundation

/// How layouts use a display while the Windows feature is on: room kept free for Stage
/// Manager's strip, space around and between tiles, thirds along a tall display and half
/// sizes that cycle. `.legacy` changes nothing, so layouts land where they always did.
public struct WindowLayoutOptions: Equatable, Sendable {
    /// Space around the usable area and between tiles that meet inside it, in points.
    public var gap: CGFloat = 0
    /// Thirds run top to bottom on a display taller than wide.
    public var portraitThirds = false
    /// Kept free on the left of every display, where Stage Manager shows its strip.
    public var leadingInset: CGFloat = 0
    /// A half shortcut pressed again cycles the window through ½, ⅔ and ⅓.
    public var cycleSizes = false

    public static let legacy = Self()
    /// The width of Stage Manager's strip of recent apps.
    public static let stageManagerInset: CGFloat = 190

    public init(gap: CGFloat = 0, portraitThirds: Bool = false, leadingInset: CGFloat = 0, cycleSizes: Bool = false) {
        self.gap = gap; self.portraitThirds = portraitThirds; self.leadingInset = leadingInset; self.cycleSizes = cycleSizes
    }

    /// The part of a display's visible frame layouts fill: without the leading inset, then
    /// without the gap on every side. Each is kept to a share of the display, so a narrow or
    /// short display still has room for a window.
    public func usableArea(_ visibleFrame: CGRect) -> CGRect {
        guard leadingInset > 0 || gap > 0 else { return visibleFrame }
        var area = visibleFrame
        let inset = min(max(0, leadingInset), area.width / 2)
        area.origin.x += inset
        area.size.width -= inset
        let space = min(max(0, gap), area.width / 4, area.height / 4)
        return area.insetBy(dx: space, dy: space)
    }

    /// A tile with half the gap taken from every edge that lies inside the area, so tiles that
    /// meet are one gap apart and tiles at the edge keep the area's own margin.
    public func spaced(_ tile: CGRect, in area: CGRect) -> CGRect {
        guard gap > 0 else { return tile }
        let half = gap / 2
        let minX = tile.minX + (abs(tile.minX - area.minX) <= 1 ? 0 : half)
        let maxX = tile.maxX - (abs(tile.maxX - area.maxX) <= 1 ? 0 : half)
        let minY = tile.minY + (abs(tile.minY - area.minY) <= 1 ? 0 : half)
        let maxY = tile.maxY - (abs(tile.maxY - area.maxY) <= 1 ? 0 : half)
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }
}

/// The sizes a half shortcut steps through when pressed again on a window still where Frog
/// put it: the width for left and right, the height for top and bottom.
public enum WindowSizeCycle {
    public static let fractions: [CGFloat] = [1 / 2, 2 / 3, 1 / 3]

    public static func cycles(_ action: WindowAction) -> Bool {
        [.leftHalf, .rightHalf, .topHalf, .bottomHalf].contains(action)
    }

    public static func next(after step: Int) -> Int { (max(0, step) + 1) % fractions.count }
}
