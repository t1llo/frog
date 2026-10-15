import XCTest
@testable import FrogCore

final class SnapDragSessionTests: XCTestCase {
    private let laptop = WindowDisplay(id: "laptop", name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                       visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875))
    private let right = WindowDisplay(id: "right", name: "Studio Display", frame: CGRect(x: 1440, y: 0, width: 1440, height: 900),
                                      visibleFrame: CGRect(x: 1440, y: 25, width: 1440, height: 875))
    /// Grabbed by the title bar, 100 pt from its left edge.
    private let window = CGRect(x: 300, y: 200, width: 800, height: 600)
    private let grab = CGPoint(x: 400, y: 210)

    private func session(lastMove: CGRect? = nil, sizeBeforeMove: CGSize? = nil, restoreOnDrag: Bool = true,
                         edgesPaused: Bool = false) -> SnapDragSession {
        SnapDragSession(window: window, pointer: grab, time: 0, lastMove: lastMove, sizeBeforeMove: sizeBeforeMove,
                        restoreOnDrag: restoreOnDrag, edgesPaused: edgesPaused)
    }

    /// Moves the pointer by (dx, dy) and reports the window moved with it.
    private func follow(_ session: inout SnapDragSession, dx: CGFloat, dy: CGFloat, time: TimeInterval = 0.1,
                        displays: [WindowDisplay]? = nil) -> [SnapDragSession.Effect] {
        session.move(to: CGPoint(x: grab.x + dx, y: grab.y + dy), time: time, windowFrame: window.offsetBy(dx: dx, dy: dy),
                     displays: displays ?? [laptop])
    }

    func testPreviewOnlyAfterTheWindowMovesWithThePointer() {
        var drag = session()
        // The pointer reaches the left edge before any frame confirms the drag.
        XCTAssertEqual(drag.move(to: CGPoint(x: 2, y: 400), time: 0.05, windowFrame: nil, displays: [laptop]), [])
        // A frame where the window has not moved: not a window drag yet.
        XCTAssertEqual(drag.move(to: CGPoint(x: 2, y: 400), time: 0.06, windowFrame: window, displays: [laptop]), [])
        XCTAssertFalse(drag.confirmed)
        XCTAssertNil(drag.end(at: CGPoint(x: 2, y: 400), time: 0.07, displays: [laptop]))

        var confirmed = session()
        XCTAssertEqual(follow(&confirmed, dx: 30, dy: 5), [.confirmDrag])
        XCTAssertEqual(confirmed.move(to: CGPoint(x: 1, y: 400), time: 0.2, windowFrame: nil, displays: [laptop]),
                       [.showPreview(SnapCandidate(action: .leftHalf, displayID: "laptop", sharedEdge: false))])
        XCTAssertEqual(confirmed.move(to: CGPoint(x: 0, y: 420), time: 0.21, windowFrame: nil, displays: [laptop]), [],
                       "The same zone again shows nothing new")
        XCTAssertEqual(confirmed.end(at: CGPoint(x: 0, y: 420), time: 0.3, displays: [laptop])?.action, .leftHalf)
    }

    func testAWindowThatLagsWithinTheToleranceConfirms() {
        var drag = session()
        _ = drag.move(to: CGPoint(x: grab.x + 20, y: grab.y), time: 0.05, windowFrame: nil, displays: [laptop])
        // Read while the pointer was 20 pt along, delivered when it is 40 pt along.
        let effects = drag.move(to: CGPoint(x: grab.x + 40, y: grab.y), time: 0.06,
                                windowFrame: window.offsetBy(dx: 18, dy: 0), displays: [laptop])
        XCTAssertEqual(effects, [.confirmDrag])
    }

    func testResizeOnlyDragsNeverPreview() {
        var drag = session()
        // A resize from the bottom-right corner: the origin stays, the size grows.
        let resized = CGRect(x: window.minX, y: window.minY, width: window.width + 40, height: window.height + 30)
        XCTAssertEqual(drag.move(to: CGPoint(x: 1139, y: 830), time: 0.1, windowFrame: resized, displays: [laptop]), [])
        XCTAssertTrue(drag.finished)
        XCTAssertEqual(drag.move(to: CGPoint(x: 1439, y: 400), time: 0.2, windowFrame: window.offsetBy(dx: 300, dy: 0), displays: [laptop]), [])
        XCTAssertNil(drag.end(at: CGPoint(x: 1439, y: 400), time: 0.3, displays: [laptop]))

        // A resize from the left edge moves the origin too, but changes the width.
        var left = session()
        let fromLeft = CGRect(x: window.minX - 30, y: window.minY, width: window.width + 30, height: window.height)
        XCTAssertEqual(left.move(to: CGPoint(x: grab.x - 30, y: grab.y), time: 0.1, windowFrame: fromLeft, displays: [laptop]), [])
        XCTAssertFalse(left.confirmed)
    }

    func testSharedEdgeNeedsTheDwell() {
        var drag = session()
        let displays = [laptop, right]
        _ = follow(&drag, dx: 10, dy: 0, displays: displays)
        let edge = CGPoint(x: 1439, y: 400)
        XCTAssertEqual(drag.move(to: edge, time: 1.0, windowFrame: nil, displays: displays), [])
        XCTAssertEqual(drag.dwellDeadline ?? 0, 1.3, accuracy: 0.0001)
        XCTAssertEqual(drag.move(to: edge, time: 1.29, windowFrame: nil, displays: displays), [])
        XCTAssertNil(drag.end(at: edge, time: 1.29, displays: displays))
        let candidate = SnapCandidate(action: .rightHalf, displayID: "laptop", sharedEdge: true)
        XCTAssertEqual(drag.end(at: edge, time: 1.31, displays: displays), candidate, "Resting long enough counts at release")
        XCTAssertEqual(drag.move(to: edge, time: 1.31, windowFrame: nil, displays: displays), [.showPreview(candidate)])
        XCTAssertNil(drag.dwellDeadline)

        // Crossing to the other display restarts the wait there.
        XCTAssertEqual(drag.move(to: CGPoint(x: 1441, y: 400), time: 1.32, windowFrame: nil, displays: displays), [.hidePreview])
        XCTAssertNil(drag.end(at: CGPoint(x: 1441, y: 400), time: 1.4, displays: displays))
        // An outer edge counts at once.
        XCTAssertEqual(drag.move(to: CGPoint(x: 2879, y: 400), time: 1.5, windowFrame: nil, displays: displays),
                       [.showPreview(SnapCandidate(action: .rightHalf, displayID: "right", sharedEdge: false))])
    }

    func testLeavingTheZoneHidesThePreview() {
        var drag = session()
        _ = follow(&drag, dx: 10, dy: 0)
        XCTAssertEqual(drag.move(to: CGPoint(x: 700, y: 1), time: 0.2, windowFrame: nil, displays: [laptop]),
                       [.showPreview(SnapCandidate(action: .maximize, displayID: "laptop", sharedEdge: false))])
        XCTAssertEqual(drag.move(to: CGPoint(x: 700, y: 60), time: 0.3, windowFrame: nil, displays: [laptop]), [.hidePreview])
        XCTAssertEqual(drag.move(to: CGPoint(x: 700, y: 80), time: 0.4, windowFrame: nil, displays: [laptop]), [])
        XCTAssertNil(drag.end(at: CGPoint(x: 700, y: 80), time: 0.5, displays: [laptop]))
    }

    func testCancelHidesAndTheReleaseAppliesNothing() {
        var drag = session()
        _ = follow(&drag, dx: 10, dy: 0)
        XCTAssertEqual(drag.move(to: CGPoint(x: 0, y: 400), time: 0.2, windowFrame: nil, displays: [laptop]).count, 1)
        XCTAssertEqual(drag.cancel(), [.hidePreview])
        XCTAssertEqual(drag.move(to: CGPoint(x: 0, y: 410), time: 0.3, windowFrame: nil, displays: [laptop]), [])
        XCTAssertNil(drag.end(at: CGPoint(x: 0, y: 410), time: 0.4, displays: [laptop]))
        XCTAssertEqual(drag.cancel(), [], "Nothing left to hide")
    }

    func testRestoreSizeOnceFromAMatchingLastMoveKeepingThePointersPlace() {
        let earlier = CGSize(width: 400, height: 300)
        var drag = session(lastMove: window, sizeBeforeMove: earlier)
        XCTAssertEqual(follow(&drag, dx: 6, dy: 0), [.confirmDrag], "Not far enough yet")
        let effects = drag.move(to: CGPoint(x: grab.x + 12, y: grab.y + 4), time: 0.2, windowFrame: nil, displays: [laptop])
        // The pointer was an eighth across the window's width, 10 pt below its top.
        XCTAssertEqual(effects, [.restoreSize(CGRect(x: 412 - 50, y: 214 - 10, width: 400, height: 300))])
        XCTAssertEqual(drag.move(to: CGPoint(x: grab.x + 40, y: grab.y), time: 0.3, windowFrame: nil, displays: [laptop]), [],
                       "Only once")

        // The window was moved or resized since Frog put it there.
        for lastMove in [window.offsetBy(dx: 30, dy: 0), CGRect(x: 300, y: 200, width: 760, height: 600)] {
            var other = session(lastMove: lastMove, sizeBeforeMove: earlier)
            XCTAssertEqual(follow(&other, dx: 40, dy: 0), [.confirmDrag], "\(lastMove)")
        }
        var off = session(lastMove: window, sizeBeforeMove: earlier, restoreOnDrag: false)
        XCTAssertEqual(follow(&off, dx: 40, dy: 0), [.confirmDrag])
        var none = session(lastMove: nil, sizeBeforeMove: nil)
        XCTAssertEqual(follow(&none, dx: 40, dy: 0), [.confirmDrag])

        // Read after the window had already followed the pointer 5 pt from the mouse-down.
        var late = SnapDragSession(window: window.offsetBy(dx: 5, dy: 0), pointer: grab, time: 0, lastMove: window,
                                   sizeBeforeMove: earlier, restoreOnDrag: true, edgesPaused: false, travel: 5)
        let lateEffects = late.move(to: CGPoint(x: grab.x + 20, y: grab.y), time: 0.1,
                                    windowFrame: window.offsetBy(dx: 25, dy: 0), displays: [laptop])
        XCTAssertEqual(lateEffects.first, .confirmDrag)
        XCTAssertEqual(lateEffects.count, 2)
    }

    func testPausedEdgesStillRestoreButNeverPreview() {
        var drag = session(lastMove: window, sizeBeforeMove: CGSize(width: 400, height: 300), edgesPaused: true)
        let effects = follow(&drag, dx: 20, dy: 0)
        XCTAssertEqual(effects.count, 2)
        XCTAssertEqual(drag.move(to: CGPoint(x: 0, y: 400), time: 0.2, windowFrame: nil, displays: [laptop]), [])
        XCTAssertNil(drag.end(at: CGPoint(x: 0, y: 400), time: 0.3, displays: [laptop]))
    }
    // MARK: Zone overlay

    /// Confirms a drag and holds Shift with thirds over the laptop.
    private func shifted(edgeTiling: Bool = false, topEdgeTiling: Bool = false, optionAccelerator: Bool = false, optionDown: Bool = false,
                         displays: [WindowDisplay]? = nil, at pointer: CGPoint = CGPoint(x: 700, y: 400)) -> (SnapDragSession, [SnapDragSession.Effect]) {
        var drag = session(edgesPaused: edgeTiling)
        _ = follow(&drag, dx: 10, dy: 0, displays: displays)
        let macOS = MacWindowManagerSettings(edgeTiling: edgeTiling, topEdgeTiling: topEdgeTiling, optionAccelerator: optionAccelerator)
        let effects = drag.shiftChanged(true, pointer: pointer, time: 0.2, displays: displays ?? [laptop], grid: .thirds, options: .legacy,
                                        macOS: macOS, optionDown: optionDown)
        return (drag, effects)
    }

    private func zone(_ action: WindowAction, on display: String = "laptop") -> SnapCandidate {
        SnapCandidate(action: action, displayID: display, sharedEdge: false)
    }

    func testShiftShowsTheOverlayAndTheHighlightFollowsThePointer() {
        let (start, effects) = shifted()
        var drag = start
        XCTAssertEqual(effects, [.showOverlay(displayID: "laptop"), .highlight(.centerThird), .showPreview(zone(.centerThird))])
        XCTAssertEqual(drag.move(to: CGPoint(x: 720, y: 500), time: 0.3, windowFrame: nil, displays: [laptop]), [], "Same zone")
        XCTAssertEqual(drag.move(to: CGPoint(x: 1200, y: 500), time: 0.4, windowFrame: nil, displays: [laptop]),
                       [.highlight(.rightThird), .showPreview(zone(.rightThird))])
        XCTAssertNil(drag.dwellDeadline)
        XCTAssertEqual(drag.end(at: CGPoint(x: 1200, y: 500), time: 0.5, displays: [laptop]), zone(.rightThird))

        // Shift up hides the overlay and goes back to the edges.
        XCTAssertEqual(drag.shiftChanged(false, pointer: CGPoint(x: 1200, y: 500), time: 0.6, displays: [laptop], grid: .thirds,
                                         options: .legacy, macOS: MacWindowManagerSettings(), optionDown: false),
                       [.hideOverlay, .hidePreview])
        XCTAssertNil(drag.end(at: CGPoint(x: 1200, y: 500), time: 0.7, displays: [laptop]))
        XCTAssertEqual(drag.move(to: CGPoint(x: 0, y: 500), time: 0.8, windowFrame: nil, displays: [laptop]),
                       [.showPreview(zone(.leftHalf))])
    }

    func testShiftHeldBeforeTheDragIsConfirmedShowsTheOverlayOnConfirmation() {
        var drag = session()
        XCTAssertEqual(drag.shiftChanged(true, pointer: grab, time: 0, displays: [laptop], grid: .halves, options: .legacy,
                                         macOS: MacWindowManagerSettings(), optionDown: false), [])
        XCTAssertEqual(follow(&drag, dx: 10, dy: 0),
                       [.confirmDrag, .showOverlay(displayID: "laptop"), .highlight(.leftHalf), .showPreview(zone(.leftHalf))])
    }

    func testReleaseOverAZoneWorksWithPausedEdgesAndEscapeHidesIt() {
        var drag = shifted(edgeTiling: true).0
        XCTAssertEqual(drag.end(at: CGPoint(x: 100, y: 500), time: 0.5, displays: [laptop]), zone(.leftThird))
        XCTAssertEqual(drag.cancel(), [.hidePreview, .hideOverlay])
        XCTAssertNil(drag.end(at: CGPoint(x: 100, y: 500), time: 0.6, displays: [laptop]))
        XCTAssertEqual(drag.shiftChanged(true, pointer: CGPoint(x: 100, y: 500), time: 0.7, displays: [laptop], grid: .thirds,
                                         options: .legacy, macOS: MacWindowManagerSettings(), optionDown: false), [],
                       "Cancelled drags show nothing")
    }

    func testReleaseInTheNativeEdgeBandAppliesNothing() {
        var drag = shifted(edgeTiling: true).0
        XCTAssertEqual(drag.move(to: CGPoint(x: 3, y: 500), time: 0.3, windowFrame: nil, displays: [laptop]),
                       [.highlight(nil), .hidePreview])
        XCTAssertNil(drag.end(at: CGPoint(x: 3, y: 500), time: 0.4, displays: [laptop]))
        XCTAssertEqual(drag.move(to: CGPoint(x: 10, y: 500), time: 0.5, windowFrame: nil, displays: [laptop]),
                       [.highlight(.leftThird), .showPreview(zone(.leftThird))])
        XCTAssertEqual(drag.end(at: CGPoint(x: 10, y: 500), time: 0.6, displays: [laptop]), zone(.leftThird))

        let off = shifted(edgeTiling: false).0
        XCTAssertEqual(off.end(at: CGPoint(x: 3, y: 500), time: 0.4, displays: [laptop]), zone(.leftThird))
    }

    func testTopBandFollowsTopEdgeTiling() {
        let top = CGPoint(x: 700, y: 3)
        XCTAssertEqual(shifted(edgeTiling: true).0.end(at: top, time: 0.4, displays: [laptop]), zone(.centerThird),
                       "The menu bar counts as the zone below it")
        XCTAssertNil(shifted(edgeTiling: true, topEdgeTiling: true).0.end(at: top, time: 0.4, displays: [laptop]))
    }

    func testSharedEdgeIsNeverDead() {
        let displays = [laptop, right]
        var drag = shifted(edgeTiling: true, displays: displays).0
        XCTAssertEqual(drag.move(to: CGPoint(x: 1437, y: 500), time: 0.3, windowFrame: nil, displays: displays),
                       [.highlight(.rightThird), .showPreview(zone(.rightThird))])
        XCTAssertEqual(drag.move(to: CGPoint(x: 1443, y: 500), time: 0.4, windowFrame: nil, displays: displays),
                       [.showOverlay(displayID: "right"), .highlight(.leftThird), .showPreview(zone(.leftThird, on: "right"))],
                       "The overlay follows the pointer to the other display")
        XCTAssertNil(drag.end(at: CGPoint(x: 2877, y: 500), time: 0.5, displays: displays), "The far outer edge is dead")
    }

    func testOptionHeldMakesTheOverlayDead() {
        let (start, effects) = shifted(edgeTiling: true, optionAccelerator: true, optionDown: true)
        var drag = start
        XCTAssertEqual(effects, [.showOverlay(displayID: "laptop"), .highlight(nil)])
        for x in [100, 700, 1200] as [CGFloat] {
            XCTAssertEqual(drag.move(to: CGPoint(x: x, y: 500), time: 0.3, windowFrame: nil, displays: [laptop]), [])
            XCTAssertNil(drag.end(at: CGPoint(x: x, y: 500), time: 0.4, displays: [laptop]))
        }
        // Option released while Shift stays down.
        XCTAssertEqual(drag.shiftChanged(true, pointer: CGPoint(x: 1200, y: 500), time: 0.5, displays: [laptop], grid: .thirds, options: .legacy,
                                         macOS: MacWindowManagerSettings(edgeTiling: true, optionAccelerator: true), optionDown: false),
                       [.highlight(.rightThird), .showPreview(zone(.rightThird))])
    }
}
