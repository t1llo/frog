import XCTest
import FrogCore
@testable import FrogApp

/// Drag to snap from mouse events to window writes, through fixture windows: no monitor, no
/// panel and no real window.
@MainActor final class WindowDragTrackerTests: XCTestCase {
    private let laptop = WindowDisplay(id: "laptop", name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                       visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875))
    private let dragged = WindowKey(pid: 42, number: 1)
    private let focused = WindowKey(pid: 42, number: 2)
    private let original = CGRect(x: 300, y: 200, width: 800, height: 600)
    /// On the title bar, 100 pt from the window's left edge.
    private let grab = CGPoint(x: 400, y: 210)

    /// Counts what the tracker asks for and records what it shows.
    private final class Probe {
        var probes: [CGPoint] = []
        var reads = 0
        var running = 0
        var mostAtOnce = 0
        var previews: [CGRect?] = []
        var edgeTiling = false
        var probedKey: WindowKey?
        var slowReads = false
        /// The lookup takes this long, and reads the window's frame at its end.
        var probeDelay: UInt64 = 0
        var time: TimeInterval = 0
        var shift = false
        var zones: [SnapZoneLayout?] = []
    }

    private func makeTracker(_ access: FixtureWindowAccess, _ manager: WindowManager, _ probe: Probe) -> WindowDragTracker {
        let laptop = laptop, dragged = dragged
        return WindowDragTracker(
            probe: { point in
                probe.probes.append(point)
                if probe.probeDelay > 0 { try? await Task.sleep(nanoseconds: probe.probeDelay) }
                let key = probe.probedKey ?? dragged
                let handle = WindowHandle(key: key, element: nil)
                return access.frame(of: handle).map { (handle, $0) }
            },
            frame: { window in
                probe.reads += 1
                probe.running += 1
                probe.mostAtOnce = max(probe.mostAtOnce, probe.running)
                if probe.slowReads { try? await Task.sleep(nanoseconds: 20_000_000) }
                probe.running -= 1
                return access.frame(of: window)
            },
            apply: { action, window, display, start in
                try? await manager.apply(action, to: window, displays: [display], options: .legacy, from: start)
            },
            setFrame: { frame, window in try? access.setFrame(frame, of: window, resize: true) },
            forget: { await manager.forget($0.key) },
            preview: { probe.previews.append($0) },
            displays: { [laptop] },
            options: { .legacy },
            macOS: { MacWindowManagerSettings(edgeTiling: probe.edgeTiling) },
            lastMove: { key in await manager.lastMove(of: key).map { ($0.move.applied, $0.frame.size) } },
            shouldIgnore: { $0.key.pid == ProcessInfo.processInfo.processIdentifier },
            zoneGrid: { .thirds },
            modifiers: { (probe.shift, false) },
            showZones: { probe.zones.append($0) },
            now: { probe.time })
    }

    private func fixture() -> FixtureWindowAccess {
        let access = FixtureWindowAccess()
        access.add(dragged, frame: original)
        // Another window of the same app has the focus: a snap must not move it.
        access.add(focused, frame: CGRect(x: 50, y: 50, width: 500, height: 400))
        return access
    }

    /// Moves the pointer, and the window with it the way macOS drags a window by its title bar.
    private func drag(_ tracker: WindowDragTracker, _ access: FixtureWindowAccess, to point: CGPoint, time: TimeInterval,
                      from start: CGRect? = nil, moving: Bool = true) async {
        if moving {
            let start = start ?? original
            access.windows[dragged]?.frame = start.offsetBy(dx: point.x - grab.x, dy: point.y - grab.y)
        }
        tracker.dragged(to: point, time: time)
        await tracker.settle()
    }

    func testDragToTheLeftEdgeSnapsTheDraggedWindowNotTheFocusedOne() async {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        let tracker = makeTracker(access, manager, probe)
        tracker.mouseDown(at: grab, time: 0)
        await drag(tracker, access, to: CGPoint(x: 410, y: 210), time: 0.01)
        await drag(tracker, access, to: CGPoint(x: 420, y: 212), time: 0.02)
        XCTAssertTrue(tracker.wantsEscape, "The window moves with the pointer")
        await drag(tracker, access, to: CGPoint(x: 0, y: 400), time: 0.2)
        let leftHalf = CGRect(x: 0, y: 25, width: 720, height: 875)
        XCTAssertEqual(probe.previews, [leftHalf])
        XCTAssertEqual(access.writes, [], "Nothing moves before the release")

        tracker.mouseUp(at: CGPoint(x: 0, y: 400), time: 0.3)
        await tracker.settle()
        XCTAssertEqual(probe.previews, [leftHalf, nil])
        let origin = CGPoint(x: 0, y: 25)
        XCTAssertEqual(access.writes, [.position(dragged, origin), .size(dragged, CGSize(width: 720, height: 875)), .position(dragged, origin)])
        XCTAssertEqual(access.windows[focused]?.frame, CGRect(x: 50, y: 50, width: 500, height: 400))
        let history = await manager.lastMove(of: dragged)
        XCTAssertEqual(history?.action, .leftHalf, "Restore previous size can undo the snap")
        XCTAssertEqual(history?.frame, original, "Restore returns to where the drag began, not to where the window was dropped")
        XCTAssertEqual(probe.probes, [CGPoint(x: 410, y: 210)])
        XCTAssertLessThanOrEqual(probe.reads, 2)
        XCTAssertFalse(tracker.wantsRelease)
    }

    func testAWindowThatMovesOnWhileItIsLookedUpStillSnaps() async {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        probe.probeDelay = 30_000_000
        let tracker = makeTracker(access, manager, probe)
        tracker.mouseDown(at: grab, time: 0)
        // A quick drag: the pointer goes on 30 pt while the window under it is looked up.
        for (index, x) in [410, 420, 430, 440].enumerated() {
            let point = CGPoint(x: CGFloat(x), y: 210)
            access.windows[dragged]?.frame = original.offsetBy(dx: point.x - grab.x, dy: 0)
            tracker.dragged(to: point, time: 0.01 * Double(index + 1))
        }
        await tracker.settle()
        await drag(tracker, access, to: CGPoint(x: 460, y: 212), time: 0.06)
        XCTAssertTrue(tracker.wantsEscape, "The window moves with the pointer")
        await drag(tracker, access, to: CGPoint(x: 0, y: 400), time: 0.2)
        tracker.mouseUp(at: CGPoint(x: 0, y: 400), time: 0.3)
        await tracker.settle()
        XCTAssertEqual(access.windows[dragged]?.frame, CGRect(x: 0, y: 25, width: 720, height: 875))
    }

    func testAThrowReleasedBeforeAnyReadStillSnaps() async {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        let tracker = makeTracker(access, manager, probe)
        tracker.mouseDown(at: grab, time: 0)
        await drag(tracker, access, to: CGPoint(x: 410, y: 210), time: 0.01)
        XCTAssertEqual(probe.reads, 0, "Looked up, not read again yet")
        // The window lands at the left edge with the release, before another drag event.
        let release = CGPoint(x: 0, y: 400)
        access.windows[dragged]?.frame = original.offsetBy(dx: release.x - grab.x, dy: release.y - grab.y)
        tracker.mouseUp(at: release, time: 0.05)
        await tracker.settle()
        XCTAssertEqual(probe.reads, 1)
        XCTAssertEqual(access.windows[dragged]?.frame, CGRect(x: 0, y: 25, width: 720, height: 875))
    }

    func testAPressAndReleaseOnAWindowThatDidNotMoveSnapsNothing() async {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        let tracker = makeTracker(access, manager, probe)
        tracker.mouseDown(at: grab, time: 0)
        // Selecting text up to the left edge: the window stays.
        await drag(tracker, access, to: CGPoint(x: 410, y: 210), time: 0.01, moving: false)
        tracker.mouseUp(at: CGPoint(x: 0, y: 400), time: 0.05)
        await tracker.settle()
        XCTAssertEqual(probe.reads, 1)
        XCTAssertEqual(access.writes, [])
    }

    func testEscapeBeforeTheReleaseWritesNothing() async {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        let tracker = makeTracker(access, manager, probe)
        tracker.mouseDown(at: grab, time: 0)
        await drag(tracker, access, to: CGPoint(x: 410, y: 210), time: 0.01)
        await drag(tracker, access, to: CGPoint(x: 420, y: 210), time: 0.02)
        await drag(tracker, access, to: CGPoint(x: 0, y: 400), time: 0.2)
        tracker.escape()
        XCTAssertEqual(probe.previews.last, .some(nil))
        XCTAssertFalse(tracker.wantsEscape)
        await drag(tracker, access, to: CGPoint(x: 0, y: 420), time: 0.25)
        tracker.mouseUp(at: CGPoint(x: 0, y: 420), time: 0.3)
        await tracker.settle()
        XCTAssertEqual(access.writes, [])
        XCTAssertEqual(probe.previews.count, 2, "Shown once, hidden once")
    }

    func testFrogsOwnWindowIsNeverSnapped() async {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        let own = WindowKey(pid: ProcessInfo.processInfo.processIdentifier, number: 9)
        access.add(own, frame: original)
        probe.probedKey = own
        let tracker = makeTracker(access, manager, probe)
        tracker.mouseDown(at: grab, time: 0)
        for (index, x) in [410, 420, 200, 0].enumerated() {
            await drag(tracker, access, to: CGPoint(x: CGFloat(x), y: 400), time: 0.01 * Double(index + 1))
        }
        tracker.mouseUp(at: CGPoint(x: 0, y: 400), time: 0.3)
        await tracker.settle()
        XCTAssertEqual(probe.probes.count, 1)
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(probe.previews, [])
        XCTAssertEqual(access.writes, [])
    }

    func testNativeEdgeTilingPausesTheEdges() async {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        probe.edgeTiling = true
        let tracker = makeTracker(access, manager, probe)
        tracker.mouseDown(at: grab, time: 0)
        await drag(tracker, access, to: CGPoint(x: 410, y: 210), time: 0.01)
        await drag(tracker, access, to: CGPoint(x: 420, y: 210), time: 0.02)
        await drag(tracker, access, to: CGPoint(x: 0, y: 400), time: 0.2)
        await drag(tracker, access, to: CGPoint(x: 10, y: 5), time: 0.3)
        tracker.mouseUp(at: CGPoint(x: 10, y: 5), time: 0.4)
        await tracker.settle()
        XCTAssertEqual(probe.previews, [])
        XCTAssertEqual(access.writes, [])
    }

    func testMouseDownAloneCallsNoProbe() async {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        let tracker = makeTracker(access, manager, probe)
        for index in 0..<5 {
            tracker.mouseDown(at: CGPoint(x: 400 + CGFloat(index), y: 210), time: Double(index))
            tracker.mouseUp(at: CGPoint(x: 400 + CGFloat(index), y: 210), time: Double(index) + 0.1)
        }
        await tracker.settle()
        XCTAssertEqual(probe.probes.count, 0)
        XCTAssertEqual(probe.reads, 0)
        XCTAssertFalse(tracker.wantsRelease)
    }

    func testProbeRunsOnceAfterFourPoints() async {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        let tracker = makeTracker(access, manager, probe)
        tracker.mouseDown(at: grab, time: 0)
        await drag(tracker, access, to: CGPoint(x: 402, y: 210), time: 0.01, moving: false)
        await drag(tracker, access, to: CGPoint(x: 403, y: 210), time: 0.02, moving: false)
        XCTAssertEqual(probe.probes.count, 0)
        XCTAssertEqual(probe.reads, 0)
        XCTAssertFalse(tracker.wantsRelease, "No release monitor for a click")
        await drag(tracker, access, to: CGPoint(x: 405, y: 210), time: 0.03)
        XCTAssertEqual(probe.probes, [CGPoint(x: 405, y: 210)], "The window under the pointer, which holds it")
        XCTAssertTrue(tracker.wantsRelease)
        await drag(tracker, access, to: CGPoint(x: 420, y: 210), time: 0.04)
        await drag(tracker, access, to: CGPoint(x: 440, y: 210), time: 0.05)
        XCTAssertEqual(probe.probes.count, 1)
    }

    func testUnconfirmedDragStopsAfterTenReads() async {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        let tracker = makeTracker(access, manager, probe)
        tracker.mouseDown(at: grab, time: 0)
        // Selecting text: the pointer runs to the left edge, the window stays.
        for step in 1...30 {
            await drag(tracker, access, to: CGPoint(x: 400 - CGFloat(step) * 14, y: 400), time: Double(step) * 0.01, moving: false)
        }
        XCTAssertEqual(probe.reads, 10)
        XCTAssertEqual(probe.previews, [])
        XCTAssertFalse(tracker.wantsRelease, "Abandoned")
        tracker.mouseUp(at: CGPoint(x: 0, y: 400), time: 1)
        await tracker.settle()
        XCTAssertEqual(access.writes, [])
        XCTAssertEqual(probe.reads, 10)
    }

    func testOneFrameReadInFlight() async {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        probe.slowReads = true
        let tracker = makeTracker(access, manager, probe)
        tracker.mouseDown(at: grab, time: 0)
        await drag(tracker, access, to: CGPoint(x: 405, y: 210), time: 0.01, moving: false)
        for step in 1...20 {
            tracker.dragged(to: CGPoint(x: 405 + CGFloat(step), y: 210), time: 0.01 + Double(step) * 0.001)
            await Task.yield()
        }
        await tracker.settle()
        XCTAssertEqual(probe.mostAtOnce, 1)
        XCTAssertGreaterThanOrEqual(probe.reads, 1)
        XCTAssertLessThan(probe.reads, 20)
    }

    func testASnappedWindowGetsItsSizeBackWhenDraggedAway() async throws {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        try await manager.apply(.leftHalf, to: WindowHandle(key: dragged, element: nil), displays: [laptop])
        let snapped = CGRect(x: 0, y: 25, width: 720, height: 875)
        XCTAssertEqual(access.windows[dragged]?.frame, snapped)
        access.writes = []
        let tracker = makeTracker(access, manager, probe)
        // Grabbed 360 pt across, half the snapped width.
        let grabbed = CGPoint(x: 360, y: 35)
        tracker.mouseDown(at: grabbed, time: 0)
        func move(to point: CGPoint, time: TimeInterval) async {
            access.windows[dragged]?.frame = snapped.offsetBy(dx: point.x - grabbed.x, dy: point.y - grabbed.y)
            tracker.dragged(to: point, time: time)
            await tracker.settle()
        }
        await move(to: CGPoint(x: 365, y: 35), time: 0.01)
        await move(to: CGPoint(x: 380, y: 40), time: 0.02)
        // Half of the earlier 800 pt width on each side of the pointer, 10 pt below the top as before.
        XCTAssertEqual(access.writes.last, .position(dragged, CGPoint(x: 380 - 400, y: 40 - 10)))
        XCTAssertTrue(access.writes.contains(.size(dragged, CGSize(width: 800, height: 600))))
        tracker.mouseUp(at: CGPoint(x: 380, y: 40), time: 0.1)
        await tracker.settle()
        let history = await manager.lastMove(of: dragged)
        XCTAssertNil(history, "Dropped with its own size back, the window has nothing left to restore")
    }

    func testASnappedWindowDraggedAwayAndSnappedAgainRestoresItsFrameFromBeforeTheFirstSnap() async throws {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        try await manager.apply(.leftHalf, to: WindowHandle(key: dragged, element: nil), displays: [laptop])
        let tracker = makeTracker(access, manager, probe)
        var pointer = CGPoint(x: 360, y: 35)
        tracker.mouseDown(at: pointer, time: 0)
        // The window keeps its place under the pointer, whatever size it has.
        func move(to point: CGPoint, time: TimeInterval) async {
            access.windows[dragged]?.frame = access.windows[dragged]?.frame?.offsetBy(dx: point.x - pointer.x, dy: point.y - pointer.y)
            pointer = point
            tracker.dragged(to: point, time: time)
            await tracker.settle()
        }
        await move(to: CGPoint(x: 365, y: 35), time: 0.01)
        await move(to: CGPoint(x: 380, y: 40), time: 0.02)
        XCTAssertEqual(access.windows[dragged]?.frame?.size, CGSize(width: 800, height: 600))
        await move(to: CGPoint(x: 1439, y: 400), time: 0.2)
        tracker.mouseUp(at: CGPoint(x: 1439, y: 400), time: 0.3)
        await tracker.settle()
        XCTAssertEqual(access.windows[dragged]?.frame, CGRect(x: 720, y: 25, width: 720, height: 875))
        try await manager.apply(.restore, to: WindowHandle(key: dragged, element: nil), displays: [laptop])
        XCTAssertEqual(access.windows[dragged]?.frame, original)
    }

    func testWithShiftHeldTheReleaseInTheRightThirdAppliesIt() async {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        // macOS tiles at the edges, so Frog's edges are paused; the zones still work.
        probe.edgeTiling = true
        let tracker = makeTracker(access, manager, probe)
        tracker.mouseDown(at: grab, time: 0)
        await drag(tracker, access, to: CGPoint(x: 410, y: 210), time: 0.01)
        await drag(tracker, access, to: CGPoint(x: 420, y: 210), time: 0.02)
        XCTAssertEqual(probe.zones, [])
        probe.shift = true
        tracker.modifiersChanged(shift: true, option: false)
        XCTAssertEqual(probe.zones.last??.frame, laptop.visibleFrame)
        XCTAssertEqual(probe.zones.last??.zones.map(\.action), [.leftThird, .centerThird, .rightThird])
        XCTAssertEqual(probe.zones.last??.highlight, .leftThird)
        await drag(tracker, access, to: CGPoint(x: 1200, y: 500), time: 0.2)
        XCTAssertEqual(probe.zones.last??.highlight, .rightThird)
        let rightThird = CGRect(x: 960, y: 25, width: 480, height: 875)
        XCTAssertEqual(probe.previews.last, rightThird)
        XCTAssertEqual(access.writes, [], "Nothing moves before the release")

        tracker.mouseUp(at: CGPoint(x: 1200, y: 500), time: 0.3)
        await tracker.settle()
        XCTAssertEqual(probe.zones.last, .some(nil), "The overlay hides")
        XCTAssertEqual(access.windows[dragged]?.frame, rightThird)
        let history = await manager.lastMove(of: dragged)
        XCTAssertEqual(history?.action, .rightThird)
    }

    func testShiftHeldBeforeTheDragAndReleasedMidway() async {
        let access = fixture(), manager = WindowManager(access: access), probe = Probe()
        probe.shift = true
        let tracker = makeTracker(access, manager, probe)
        tracker.mouseDown(at: grab, time: 0)
        await drag(tracker, access, to: CGPoint(x: 410, y: 210), time: 0.01)
        await drag(tracker, access, to: CGPoint(x: 420, y: 210), time: 0.02)
        XCTAssertEqual(probe.zones.last??.highlight, .leftThird, "Shown as soon as the window follows")
        probe.shift = false
        tracker.modifiersChanged(shift: false, option: false)
        XCTAssertEqual(probe.zones.last, .some(nil))
        await drag(tracker, access, to: CGPoint(x: 700, y: 500), time: 0.2)
        tracker.mouseUp(at: CGPoint(x: 700, y: 500), time: 0.3)
        await tracker.settle()
        XCTAssertEqual(access.writes, [], "Back to the edges, and the middle is no edge")
    }
}
