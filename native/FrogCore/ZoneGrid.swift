import Foundation

/// The zones Frog shows while a window is dragged with Shift held, as shares of the usable area
/// of the display under the pointer. Each zone is a layout, named by its `WindowAction`.
public enum ZoneGrid: String, CaseIterable, Sendable {
    case halves, thirds, quarters
    case mainSide = "main-side"

    public static let `default` = ZoneGrid.thirds

    public var title: String {
        switch self {
        case .halves: "Halves"
        case .thirds: "Thirds"
        case .quarters: "Quarters"
        case .mainSide: "Main and side"
        }
    }

    /// The layouts of the zones, left to right and top to bottom.
    public var actions: [WindowAction] {
        switch self {
        case .halves: [.leftHalf, .rightHalf]
        case .thirds: [.leftThird, .centerThird, .rightThird]
        case .quarters: [.topLeft, .topRight, .bottomLeft, .bottomRight]
        case .mainSide: [.leftTwoThirds, .rightThird]
        }
    }

    /// The zones, which tile `area` exactly. With `portrait`, thirds and main and side run top
    /// to bottom, the way layouts do on a tall display with portrait thirds on.
    public func rects(in area: CGRect, portrait: Bool) -> [(WindowAction, CGRect)] {
        func columns(_ shares: [CGFloat]) -> [CGRect] {
            let edges = shares.map { area.minX + area.width * $0 }
            return zip(edges, edges.dropFirst()).map { CGRect(x: $0, y: area.minY, width: $1 - $0, height: area.height) }
        }
        func rows(_ shares: [CGFloat]) -> [CGRect] {
            let edges = shares.map { area.minY + area.height * $0 }
            return zip(edges, edges.dropFirst()).map { CGRect(x: area.minX, y: $0, width: area.width, height: $1 - $0) }
        }
        let tiles: [CGRect]
        switch self {
        case .halves: tiles = columns([0, 0.5, 1])
        case .thirds: tiles = portrait ? rows([0, 1.0 / 3, 2.0 / 3, 1]) : columns([0, 1.0 / 3, 2.0 / 3, 1])
        case .mainSide: tiles = portrait ? rows([0, 2.0 / 3, 1]) : columns([0, 2.0 / 3, 1])
        case .quarters:
            let top = CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2)
            let bottom = CGRect(x: area.minX, y: top.maxY, width: area.width, height: area.maxY - top.maxY)
            tiles = [top, bottom].flatMap { half in
                [CGRect(x: half.minX, y: half.minY, width: area.width / 2, height: half.height),
                 CGRect(x: area.minX + area.width / 2, y: half.minY, width: area.maxX - (area.minX + area.width / 2), height: half.height)]
            }
        }
        return Array(zip(actions, tiles))
    }

    /// The zone holding the point. A zone holds its left and top edges, and the last zone its
    /// far edge too, so every point of the area, edges included, is in exactly one zone.
    public func zone(at point: CGPoint, in area: CGRect, portrait: Bool) -> WindowAction? {
        guard area.width > 0, area.height > 0,
              point.x >= area.minX, point.x <= area.maxX, point.y >= area.minY, point.y <= area.maxY else { return nil }
        return rects(in: area, portrait: portrait).first { _, rect in
            (point.x < rect.maxX || rect.maxX >= area.maxX) && point.x >= rect.minX
                && (point.y < rect.maxY || rect.maxY >= area.maxY) && point.y >= rect.minY
        }?.0
    }
}
