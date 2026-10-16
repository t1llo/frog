import XCTest
@testable import FrogCore

final class SnapZoneResolverTests: XCTestCase {
    private let laptop = WindowDisplay(id: "laptop", name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                       visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875))
    private let right = WindowDisplay(id: "right", name: "Studio Display", frame: CGRect(x: 1440, y: -200, width: 2560, height: 1440),
                                      visibleFrame: CGRect(x: 1440, y: -175, width: 2560, height: 1415))
    private let above = WindowDisplay(id: "above", name: "Monitor", frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                                      visibleFrame: CGRect(x: 0, y: -1055, width: 1920, height: 1055))

    private func action(_ x: CGFloat, _ y: CGFloat, _ displays: [WindowDisplay]? = nil) -> WindowAction? {
        SnapZoneResolver.candidate(at: CGPoint(x: x, y: y), displays: displays ?? [laptop], edgesPaused: false)?.action
    }

    func testEveryZoneOnOneDisplay() {
        XCTAssertEqual(action(0, 400), .leftHalf)
        XCTAssertEqual(action(1439, 400), .rightHalf)
        XCTAssertEqual(action(700, 0), .maximize)
        XCTAssertEqual(action(5, 400), .leftHalf)
        XCTAssertEqual(action(10, 10), .topLeft)
        XCTAssertEqual(action(1430, 3), .topRight)
        XCTAssertEqual(action(2, 899), .bottomLeft)
        XCTAssertEqual(action(1439, 885), .bottomRight)
        let candidate = SnapZoneResolver.candidate(at: CGPoint(x: 0, y: 400), displays: [laptop], edgesPaused: false)
        XCTAssertEqual(candidate, SnapCandidate(action: .leftHalf, displayID: "laptop", sharedEdge: false))
    }

    func testJustOutsideTheMarginIsNoZone() {
        XCTAssertNil(action(6, 400))
        XCTAssertNil(action(1440 - 6, 400))
        XCTAssertNil(action(700, 6))
        XCTAssertNil(action(700, 900 - 6))
        XCTAssertNil(action(700, 400))
        XCTAssertNil(action(21, 21), "Outside the corner square and away from the edges")
        XCTAssertNil(action(-50, 400), "No display under the pointer")
    }

    func testBottomEdgeGivesTheThirdUnderThePointer() {
        XCTAssertEqual(action(100, 898), .leftThird)
        XCTAssertEqual(action(479, 898), .leftThird)
        XCTAssertEqual(action(481, 898), .centerThird)
        XCTAssertEqual(action(959, 898), .centerThird)
        XCTAssertEqual(action(961, 898), .rightThird)
        XCTAssertEqual(action(1400, 898), .rightThird)
    }

    func testSharedEdgeOfSideBySideDisplaysIsFlagged() {
        let displays = [laptop, right]
        func candidate(_ x: CGFloat, _ y: CGFloat) -> SnapCandidate? {
            SnapZoneResolver.candidate(at: CGPoint(x: x, y: y), displays: displays, edgesPaused: false)
        }
        XCTAssertEqual(candidate(1439, 400), SnapCandidate(action: .rightHalf, displayID: "laptop", sharedEdge: true))
        XCTAssertEqual(candidate(1440, 400), SnapCandidate(action: .leftHalf, displayID: "right", sharedEdge: true))
        XCTAssertEqual(candidate(0, 400), SnapCandidate(action: .leftHalf, displayID: "laptop", sharedEdge: false))
        XCTAssertEqual(candidate(3999, 400), SnapCandidate(action: .rightHalf, displayID: "right", sharedEdge: false))
        XCTAssertEqual(candidate(700, 0)?.sharedEdge, false, "The laptop's top edge touches no display")
        // The tall display reaches below the laptop: its left edge there touches nothing.
        XCTAssertEqual(candidate(1440, 1100), SnapCandidate(action: .leftHalf, displayID: "right", sharedEdge: false))
    }

    func testStackedDisplaysFlagTopAndBottom() {
        let displays = [laptop, above]
        func candidate(_ x: CGFloat, _ y: CGFloat) -> SnapCandidate? {
            SnapZoneResolver.candidate(at: CGPoint(x: x, y: y), displays: displays, edgesPaused: false)
        }
        XCTAssertEqual(candidate(700, 0), SnapCandidate(action: .maximize, displayID: "laptop", sharedEdge: true))
        XCTAssertEqual(candidate(700, -1), SnapCandidate(action: .centerThird, displayID: "above", sharedEdge: true))
        XCTAssertEqual(candidate(700, -1080), SnapCandidate(action: .maximize, displayID: "above", sharedEdge: false))
        XCTAssertEqual(candidate(700, 899)?.sharedEdge, false)
        XCTAssertEqual(candidate(1700, -1)?.sharedEdge, false, "The laptop ends at 1440, so this bottom edge is outer")
        XCTAssertEqual(candidate(10, 10), SnapCandidate(action: .topLeft, displayID: "laptop", sharedEdge: true))
    }

    func testPausedEdgesGiveNothing() {
        for point in [CGPoint(x: 0, y: 400), CGPoint(x: 1439, y: 400), CGPoint(x: 700, y: 0), CGPoint(x: 700, y: 899), CGPoint(x: 5, y: 5)] {
            XCTAssertNil(SnapZoneResolver.candidate(at: point, displays: [laptop, right], edgesPaused: true), "\(point)")
        }
    }
    func testAPausedTopLeavesTheMenuBarToMacOS() {
        func candidate(_ x: CGFloat, _ y: CGFloat, _ displays: [WindowDisplay]) -> SnapCandidate? {
            SnapZoneResolver.candidate(at: CGPoint(x: x, y: y), displays: displays, edgesPaused: false, topPaused: true)
        }
        for point in [CGPoint(x: 700, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 1430, y: 3), CGPoint(x: 2, y: 2)] {
            XCTAssertNil(candidate(point.x, point.y, [laptop]), "\(point)")
        }
        XCTAssertEqual(candidate(0, 400, [laptop])?.action, .leftHalf)
        XCTAssertEqual(candidate(1439, 400, [laptop])?.action, .rightHalf)
        XCTAssertEqual(candidate(2, 899, [laptop])?.action, .bottomLeft)
        XCTAssertEqual(candidate(700, 898, [laptop])?.action, .centerThird)
        // Under another display the top edge leads there, not to a menu bar macOS fills from.
        XCTAssertEqual(candidate(700, 0, [laptop, above]), SnapCandidate(action: .maximize, displayID: "laptop", sharedEdge: true))
        XCTAssertNil(candidate(700, -1080, [laptop, above]), "The upper display's own top edge")
    }

    func testNativeEdgeBand() {
        func dead(_ x: CGFloat, _ y: CGFloat, _ macOS: MacWindowManagerSettings, option: Bool = false,
                  _ displays: [WindowDisplay]? = nil) -> Bool {
            SnapZoneResolver.nativeEdgeBand(at: CGPoint(x: x, y: y), displays: displays ?? [laptop], macOS: macOS, optionDown: option)
        }
        let edges = MacWindowManagerSettings(edgeTiling: true)
        XCTAssertTrue(dead(3, 400, edges))
        XCTAssertTrue(dead(1437, 400, edges))
        XCTAssertTrue(dead(700, 897, edges))
        XCTAssertFalse(dead(700, 3, edges), "The top follows top-edge tiling")
        XCTAssertFalse(dead(7, 400, edges))
        XCTAssertFalse(dead(700, 400, edges))
        XCTAssertTrue(dead(700, 3, MacWindowManagerSettings(topEdgeTiling: true)))
        XCTAssertFalse(dead(3, 400, MacWindowManagerSettings(topEdgeTiling: true)))
        for point in [CGPoint(x: 3, y: 400), CGPoint(x: 700, y: 3), CGPoint(x: 700, y: 400)] {
            XCTAssertFalse(dead(point.x, point.y, MacWindowManagerSettings()), "All settings off")
            XCTAssertFalse(dead(point.x, point.y, MacWindowManagerSettings(), option: true), "Option without the accelerator")
            XCTAssertTrue(dead(point.x, point.y, MacWindowManagerSettings(optionAccelerator: true), option: true))
        }
        // The laptop's right edge touches the larger display; its top touches the one above.
        let all = MacWindowManagerSettings(edgeTiling: true, topEdgeTiling: true)
        XCTAssertFalse(dead(1437, 400, all, [laptop, right]))
        XCTAssertFalse(dead(1443, 400, all, [laptop, right]))
        XCTAssertFalse(dead(700, 3, all, [laptop, above]))
        XCTAssertFalse(dead(700, -3, all, [laptop, above]))
        XCTAssertTrue(dead(3, 400, all, [laptop, right, above]))
        XCTAssertFalse(dead(1437, 880, all, [laptop, right]), "Shared where the other display spans the pointer")
    }
}
