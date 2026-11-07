import CoreGraphics

/// One placement for the keyboard panels: the command bar, clipboard history and the window switcher. They are one
/// family, as Raycast's views are one window: the same width, and each hangs from the same point, the centre of its
/// top edge, so the search line opens in the same place whichever panel it is and only the bottom edge moves with
/// the content. A drag moves that point for the whole family, remembered for each display; dragging it back to the
/// default place (within `snapDistance`) or resetting forgets it.
///
/// Every value is in Cocoa coordinates: origin at the bottom left of the primary display, y growing upwards.
public enum PanelFamilyPlacement {
    /// The family's one width.
    public static let width: CGFloat = 680
    /// The tallest the family gets: the command bar and clipboard history are this tall, the window switcher at most.
    public static let height: CGFloat = 460
    /// The least room kept between a panel and the edge of the display's free area.
    public static let margin: CGFloat = 8
    /// A drag that ends this close to the default place, on both axes, snaps back to it and forgets the spot.
    public static let snapDistance: CGFloat = 24
    /// At its default place the tallest panel leaves two fifths of the free height above it and three below, a
    /// little above the middle, where the eye rests.
    static let shareAbove: CGFloat = 0.4

    /// A display: an ID that stays the same across launches, its frame and its free area (no menu bar or Dock).
    public struct Display: Equatable, Sendable {
        public var id: String
        public var frame: CGRect
        public var visibleFrame: CGRect
        public init(id: String, frame: CGRect, visibleFrame: CGRect) {
            self.id = id; self.frame = frame; self.visibleFrame = visibleFrame
        }
    }

    /// Where the family's top centre was put on a display, from the top left of its free area: `x` to the right,
    /// `top` downwards. Kept relative, so it holds when the display is arranged elsewhere beside another.
    public struct Spot: Codable, Equatable, Sendable {
        public var x: Double
        public var top: Double
        public init(x: Double, top: Double) { self.x = x; self.top = top }
    }

    /// The spots the person dragged the family to, by display ID. A display without one uses the default place.
    public struct Memory: Codable, Equatable, Sendable {
        public var displays: [String: Spot]
        public init(displays: [String: Spot] = [:]) { self.displays = displays }
    }

    /// The display the family opens on: the one under the pointer, else the first (the primary display).
    public static func display(at pointer: CGPoint, in displays: [Display]) -> Display? {
        displays.first { $0.frame.contains(pointer) } ?? displays.first
    }

    /// The display that shows most of `frame`, which is where a drag left it.
    public static func display(holding frame: CGRect, in displays: [Display]) -> Display? {
        let shown = displays.map { display -> (Display, CGFloat) in
            let overlap = display.frame.intersection(frame)
            return (display, overlap.isNull ? 0 : overlap.width * overlap.height)
        }
        guard let best = shown.max(by: { $0.1 < $1.1 }), best.1 > 0 else {
            return display(at: CGPoint(x: frame.midX, y: frame.maxY), in: displays)
        }
        return best.0
    }

    /// The default top centre on a display's free area.
    public static func defaultTopCentre(in visible: CGRect) -> CGPoint {
        let free = max(0, visible.height - height)
        return CGPoint(x: visible.midX.rounded(), y: (visible.maxY - max(margin, free * shareAbove)).rounded())
    }

    /// The family's top centre on a display: where it was dragged to there, else the default place.
    public static func topCentre(on display: Display, memory: Memory) -> CGPoint {
        let visible = display.visibleFrame
        guard let spot = memory.displays[display.id] else { return defaultTopCentre(in: visible) }
        return CGPoint(x: visible.minX + spot.x, y: visible.maxY - spot.top)
    }

    /// A panel of `size` hanging from `topCentre`, kept wholly inside the free area.
    public static func frame(size: CGSize, hangingFrom topCentre: CGPoint, in visible: CGRect) -> CGRect {
        clamp(CGRect(x: (topCentre.x - size.width / 2).rounded(), y: topCentre.y - size.height, width: size.width, height: size.height), in: visible)
    }

    /// Where a panel of `size` opens: on the display under the pointer, at the family's place there.
    public static func opening(size: CGSize, pointer: CGPoint, displays: [Display], memory: Memory) -> CGRect? {
        guard let display = display(at: pointer, in: displays) else { return nil }
        return frame(size: size, hangingFrom: topCentre(on: display, memory: memory), in: display.visibleFrame)
    }

    /// The panel at a new size, still hanging from the same top centre: a list that grows or shrinks moves only the
    /// bottom edge, and stays on the display it is on.
    public static func resized(_ frame: CGRect, to size: CGSize, displays: [Display]) -> CGRect {
        let topCentre = CGPoint(x: frame.midX, y: frame.maxY)
        let resized = CGRect(x: (topCentre.x - size.width / 2).rounded(), y: topCentre.y - size.height, width: size.width, height: size.height)
        guard let display = display(holding: frame, in: displays) else { return resized }
        return clamp(resized, in: display.visibleFrame)
    }

    /// What a drag that left a panel at `frame` changes: the family's spot on that display, or none when it ended
    /// near the default place, which snaps it back there. `frame` is where the panel is to be shown now.
    public struct Drag: Equatable, Sendable {
        public var memory: Memory
        public var frame: CGRect
        /// The drag left the family away from its default place on that display.
        public var placed: Bool
    }

    public static func finishDrag(_ frame: CGRect, displays: [Display], memory: Memory) -> Drag {
        guard let display = display(holding: frame, in: displays) else { return Drag(memory: memory, frame: frame, placed: false) }
        let visible = display.visibleFrame
        let shown = clamp(frame, in: visible)
        let topCentre = CGPoint(x: shown.midX, y: shown.maxY)
        let home = defaultTopCentre(in: visible)
        var memory = memory
        if abs(topCentre.x - home.x) <= snapDistance, abs(topCentre.y - home.y) <= snapDistance {
            memory.displays[display.id] = nil
            return Drag(memory: memory, frame: Self.frame(size: frame.size, hangingFrom: home, in: visible), placed: false)
        }
        memory.displays[display.id] = Spot(x: Double(topCentre.x - visible.minX), top: Double(visible.maxY - topCentre.y))
        return Drag(memory: memory, frame: shown, placed: true)
    }

    /// Forgets the spot on the display that shows `frame`, and gives the panel's frame at the default place there.
    public static func reset(_ frame: CGRect, displays: [Display], memory: Memory) -> (memory: Memory, frame: CGRect) {
        guard let display = display(holding: frame, in: displays) else { return (memory, frame) }
        var memory = memory
        memory.displays[display.id] = nil
        return (memory, Self.frame(size: frame.size, hangingFrom: defaultTopCentre(in: display.visibleFrame), in: display.visibleFrame))
    }

    /// Whether the family was dragged away from its default place on the display that shows `frame`.
    public static func isPlaced(_ frame: CGRect, displays: [Display], memory: Memory) -> Bool {
        guard let display = display(holding: frame, in: displays) else { return false }
        return memory.displays[display.id] != nil
    }

    /// `frame` moved the least needed to lie `margin` inside `visible`. A panel taller than the area keeps its top
    /// edge, so the search line stays reachable; one wider than it is centred.
    public static func clamp(_ frame: CGRect, in visible: CGRect) -> CGRect {
        let inner = visible.insetBy(dx: margin, dy: margin)
        guard !inner.isNull, !inner.isEmpty else { return frame }
        var result = frame
        if result.width >= inner.width { result.origin.x = (inner.midX - result.width / 2).rounded() }
        else { result.origin.x = min(max(result.minX, inner.minX), inner.maxX - result.width) }
        if result.height >= inner.height { result.origin.y = inner.maxY - result.height }
        else { result.origin.y = min(max(result.minY, inner.minY), inner.maxY - result.height) }
        return result
    }
}
