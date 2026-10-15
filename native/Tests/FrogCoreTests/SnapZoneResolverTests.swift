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
}
