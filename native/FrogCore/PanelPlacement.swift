import CoreGraphics

/// Places a floating panel next to an anchor such as a text selection, on whichever display the anchor is on.
/// Every value is in Cocoa coordinates: origin at the bottom left of the primary display, y growing upwards.
public enum PanelPlacement {
    public struct Result: Equatable, Sendable {
        public var frame: CGRect
        /// The panel sits above its anchor rather than below it.
        public var above: Bool
        /// The visible frame of the display the panel is on.
        public var screen: CGRect
        public init(frame: CGRect, above: Bool, screen: CGRect) {
            self.frame = frame
            self.above = above
            self.screen = screen
        }
    }

    /// Below the anchor when it fits, else above it, else on the side with more room. Without an anchor the panel
    /// opens just below and to the right of the pointer. `screens` are the displays' visible frames.
    public static func place(size: CGSize, anchor: CGRect?, pointer: CGPoint, screens: [CGRect],
                             gap: CGFloat = 8, margin: CGFloat = 8) -> Result {
        let anchor = anchor ?? CGRect(x: pointer.x + 12, y: pointer.y - 12, width: 0, height: 0)
        let screen = visibleFrame(for: anchor, pointer: pointer, screens: screens)
        let belowY = anchor.minY - gap - size.height
        let aboveY = anchor.maxY + gap
        let roomBelow = belowY - (screen.minY + margin)
        let roomAbove = (screen.maxY - margin) - (aboveY + size.height)
        let above = roomBelow < 0 && (roomAbove >= 0 || roomAbove > roomBelow)
        let frame = CGRect(x: anchor.minX, y: above ? aboveY : belowY, width: size.width, height: size.height)
        return Result(frame: clamp(frame, in: screen, margin: margin), above: above, screen: screen)
    }

    /// A panel whose content changed height: one below its anchor keeps its top edge, one above keeps its bottom edge.
    public static func resized(_ current: Result, height: CGFloat, margin: CGFloat = 8) -> Result {
        var frame = current.frame
        if !current.above { frame.origin.y = current.frame.maxY - height }
        frame.size.height = height
        return Result(frame: clamp(frame, in: current.screen, margin: margin), above: current.above, screen: current.screen)
    }

    /// The display containing the anchor's middle, else the nearest one, else the pointer's, else the first.
    static func visibleFrame(for anchor: CGRect, pointer: CGPoint, screens: [CGRect]) -> CGRect {
        let middle = CGPoint(x: anchor.midX, y: anchor.midY)
        if let containing = screens.first(where: { $0.contains(middle) }) { return containing }
        let nearest = screens.map { (screen: $0, distance: distance(from: middle, to: $0)) }
            .filter { $0.distance.isFinite }
            .min { $0.distance < $1.distance }
        if let nearest { return nearest.screen }
        return screens.first { $0.contains(pointer) } ?? screens.first ?? .zero
    }

    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Keeps the frame inside the visible frame; a panel too large for it keeps its left and top edges on screen.
    static func clamp(_ frame: CGRect, in screen: CGRect, margin: CGFloat) -> CGRect {
        guard !screen.isEmpty else { return frame }
        var frame = frame
        frame.origin.x = max(min(frame.minX, screen.maxX - margin - frame.width), screen.minX + margin)
        frame.origin.y = min(max(frame.minY, screen.minY + margin), screen.maxY - margin - frame.height)
        return frame
    }
}
