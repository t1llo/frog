import XCTest
@testable import FrogCore

final class ZoneGridTests: XCTestCase {
    /// A laptop's visible frame with an 8 pt gap taken off, so the shares are not whole points.
    private let wide = CGRect(x: 8, y: 33, width: 1424, height: 859)
    private let tall = CGRect(x: 1440, y: -400, width: 1080, height: 1895)

    func testEveryGridTilesTheAreaExactly() {
        for grid in ZoneGrid.allCases {
            for (area, portrait) in [(wide, false), (wide, true), (tall, true)] {
                let rects = grid.rects(in: area, portrait: portrait)
                XCTAssertEqual(rects.map(\.0), grid.actions, "\(grid)")
                let total = rects.reduce(0) { $0 + $1.1.width * $1.1.height }
                XCTAssertEqual(total, area.width * area.height, accuracy: 0.01, "\(grid) covers the area")
                for (index, (_, rect)) in rects.enumerated() {
                    XCTAssertTrue(area.insetBy(dx: -0.001, dy: -0.001).contains(rect), "\(grid) stays inside")
                    for (_, other) in rects[(index + 1)...] {
                        let overlap = rect.intersection(other)
                        XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.001, "\(grid) zones never overlap")
                    }
                }
                // Every point on a 1 pt raster lands in exactly one zone.
                for x in stride(from: area.minX, through: area.maxX, by: 37) {
                    for y in stride(from: area.minY, through: area.maxY, by: 41) {
                        XCTAssertNotNil(grid.zone(at: CGPoint(x: x, y: y), in: area, portrait: portrait), "\(grid) \(x),\(y)")
                    }
                }
            }
        }
    }

    func testZonesAtCentresAndBoundaries() {
        let area = CGRect(x: 0, y: 0, width: 1200, height: 900)
        for (action, rect) in ZoneGrid.thirds.rects(in: area, portrait: false) {
            XCTAssertEqual(ZoneGrid.thirds.zone(at: CGPoint(x: rect.midX, y: rect.midY), in: area, portrait: false), action)
        }
        XCTAssertEqual(ZoneGrid.thirds.zone(at: CGPoint(x: 399.9, y: 10), in: area, portrait: false), .leftThird)
        XCTAssertEqual(ZoneGrid.thirds.zone(at: CGPoint(x: 400, y: 10), in: area, portrait: false), .centerThird)
        XCTAssertEqual(ZoneGrid.thirds.zone(at: CGPoint(x: 1200, y: 900), in: area, portrait: false), .rightThird, "The far corner")
        XCTAssertEqual(ZoneGrid.halves.zone(at: CGPoint(x: 600, y: 450), in: area, portrait: false), .rightHalf)
        XCTAssertEqual(ZoneGrid.quarters.zone(at: CGPoint(x: 599, y: 449), in: area, portrait: false), .topLeft)
        XCTAssertEqual(ZoneGrid.quarters.zone(at: CGPoint(x: 600, y: 449), in: area, portrait: false), .topRight)
        XCTAssertEqual(ZoneGrid.quarters.zone(at: CGPoint(x: 599, y: 450), in: area, portrait: false), .bottomLeft)
        XCTAssertEqual(ZoneGrid.quarters.zone(at: CGPoint(x: 1199, y: 899), in: area, portrait: false), .bottomRight)
        XCTAssertEqual(ZoneGrid.mainSide.zone(at: CGPoint(x: 799, y: 10), in: area, portrait: false), .leftTwoThirds)
        XCTAssertEqual(ZoneGrid.mainSide.zone(at: CGPoint(x: 800, y: 10), in: area, portrait: false), .rightThird)
        XCTAssertNil(ZoneGrid.thirds.zone(at: CGPoint(x: -1, y: 10), in: area, portrait: false))
        XCTAssertNil(ZoneGrid.thirds.zone(at: CGPoint(x: 10, y: 901), in: area, portrait: false))
    }

    func testPortraitThirdsAndMainSideRunTopToBottom() {
        let area = CGRect(x: 0, y: 0, width: 900, height: 1500)
        let thirds = ZoneGrid.thirds.rects(in: area, portrait: true)
        XCTAssertEqual(thirds.map(\.1), [CGRect(x: 0, y: 0, width: 900, height: 500), CGRect(x: 0, y: 500, width: 900, height: 500),
                                         CGRect(x: 0, y: 1000, width: 900, height: 500)])
        XCTAssertEqual(ZoneGrid.thirds.zone(at: CGPoint(x: 10, y: 1200), in: area, portrait: true), .rightThird)
        XCTAssertEqual(ZoneGrid.mainSide.rects(in: area, portrait: true).map(\.1),
                       [CGRect(x: 0, y: 0, width: 900, height: 1000), CGRect(x: 0, y: 1000, width: 900, height: 500)])
        XCTAssertEqual(ZoneGrid.halves.rects(in: area, portrait: true).map(\.1),
                       [CGRect(x: 0, y: 0, width: 450, height: 1500), CGRect(x: 450, y: 0, width: 450, height: 1500)],
                       "Halves stay side by side")
    }

    func testTitlesAndRawValues() {
        XCTAssertEqual(ZoneGrid.allCases.map(\.rawValue), ["halves", "thirds", "quarters", "main-side"])
        XCTAssertEqual(ZoneGrid.allCases.map(\.title), ["Halves", "Thirds", "Quarters", "Main and side"])
        XCTAssertEqual(ZoneGrid.mainSide.actions.map(\.title), [WindowAction.leftTwoThirds.title, WindowAction.rightThird.title])
    }
}
