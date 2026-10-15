import XCTest
import FrogCore
@testable import FrogApp

final class WindowManagerFixtureTests: XCTestCase {
    /// A 1440×900 display with a 25 pt menu bar.
    private let laptop = WindowDisplay(id: "laptop", name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                       visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875))
    private let key = WindowKey(pid: 7, number: 1)

    private func message(_ body: () async throws -> Void) async -> String? {
        do { try await body(); return nil } catch { return error.localizedDescription }
    }

    func testLeftHalfWritesPositionSizePositionOnTheVisibleFrame() async throws {
        let access = FixtureWindowAccess()
        access.add(key, frame: CGRect(x: 200, y: 200, width: 600, height: 400))
        try await WindowManager(access: access).perform(.leftHalf, pid: 7, displays: [laptop])
        XCTAssertEqual(access.writes, [.position(key, CGPoint(x: 0, y: 25)), .size(key, CGSize(width: 720, height: 875)),
                                       .position(key, CGPoint(x: 0, y: 25))])
        XCTAssertEqual(access.windows[key]?.frame, CGRect(x: 0, y: 25, width: 720, height: 875))
    }

    func testCenterKeepsSizeAndWritesNoSize() async throws {
        let access = FixtureWindowAccess()
        access.add(key, frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        try await WindowManager(access: access).perform(.center, pid: 7, displays: [laptop])
        let origin = CGPoint(x: 520, y: 312.5)
        XCTAssertEqual(access.writes, [.position(key, origin), .position(key, origin)])
        XCTAssertEqual(access.windows[key]?.frame, CGRect(origin: origin, size: CGSize(width: 400, height: 300)))
    }

    func testSameFrameAgainWritesNothing() async throws {
        let access = FixtureWindowAccess()
        access.add(key, frame: CGRect(x: 200, y: 200, width: 600, height: 400))
        let manager = WindowManager(access: access)
        try await manager.perform(.leftHalf, pid: 7, displays: [laptop])
        access.writes = []
        try await manager.perform(.leftHalf, pid: 7, displays: [laptop])
        XCTAssertEqual(access.writes, [])
    }

    func testRestoreReturnsToTheFrameBeforeTheFirstOfRepeatedPresses() async throws {
        let access = FixtureWindowAccess()
        let original = CGRect(x: 200, y: 200, width: 900, height: 600)
        access.add(key, frame: original, minimumSize: CGSize(width: 800, height: 100))
        let manager = WindowManager(access: access)
        try await manager.perform(.leftHalf, pid: 7, displays: [laptop])
        XCTAssertEqual(access.windows[key]?.frame, CGRect(x: 0, y: 25, width: 800, height: 875))
        try await manager.perform(.leftHalf, pid: 7, displays: [laptop])
        let last = await manager.lastMove(of: key)
        XCTAssertEqual(last?.frame, original)
        XCTAssertEqual(last?.move.target, CGRect(x: 0, y: 25, width: 720, height: 875))
        XCTAssertEqual(last?.move.applied, CGRect(x: 0, y: 25, width: 800, height: 875))
        try await manager.perform(.restore, pid: 7, displays: [laptop])
        XCTAssertEqual(access.windows[key]?.frame, original)
    }

    func testRestoreWithoutHistoryAndOtherMessagesMatchToday() async {
        let access = FixtureWindowAccess()
        let manager = WindowManager(access: access)
        let frame = CGRect(x: 200, y: 200, width: 600, height: 400)

        access.trusted = false
        var text = await message { try await manager.perform(.leftHalf, pid: 7, displays: [self.laptop]) }
        XCTAssertEqual(text, "Allow Accessibility in Settings → Permissions to move windows.")
        access.trusted = true

        text = await message { try await manager.perform(.leftHalf, pid: 7, displays: [self.laptop]) }
        XCTAssertEqual(text, "There is no focused window to \(WindowAction.leftHalf.title.lowercased()).")

        access.add(key, frame: frame, state: WindowState(fullScreen: true))
        text = await message { try await manager.perform(.leftHalf, pid: 7, displays: [self.laptop]) }
        XCTAssertEqual(text, "Exit full screen before moving or resizing this window.")

        access.add(key, frame: nil)
        text = await message { try await manager.perform(.leftHalf, pid: 7, displays: [self.laptop]) }
        XCTAssertEqual(text, "macOS could not read this window's size or display.")
        access.add(key, frame: frame)
        text = await message { try await manager.perform(.leftHalf, pid: 7, displays: []) }
        XCTAssertEqual(text, "macOS could not read this window's size or display.")

        text = await message { try await manager.perform(.restore, pid: 7, displays: [self.laptop]) }
        XCTAssertEqual(text, "There is no previous size for this window yet.")

        access.add(key, frame: frame, state: WindowState(movable: false))
        text = await message { try await manager.perform(.leftHalf, pid: 7, displays: [self.laptop]) }
        XCTAssertEqual(text, "This window does not allow its position to be changed.")

        access.add(key, frame: frame, state: WindowState(resizable: false))
        text = await message { try await manager.perform(.leftHalf, pid: 7, displays: [self.laptop]) }
        XCTAssertEqual(text, "This window does not allow resizing.")
        // Centering keeps the size, so a window that cannot be resized still moves.
        text = await message { try await manager.perform(.center, pid: 7, displays: [self.laptop]) }
        XCTAssertNil(text)

        access.add(key, frame: frame)
        access.windows[key]?.refusesSize = true
        text = await message { try await manager.perform(.leftHalf, pid: 7, displays: [self.laptop]) }
        XCTAssertEqual(text, "macOS could not apply this window action. The app may not support it.")
    }

    func testHistoryKeepsTheLastFiftyWindows() async throws {
        let access = FixtureWindowAccess()
        let manager = WindowManager(access: access)
        let keys = (1...51).map { WindowKey(pid: 7, number: UInt32($0)) }
        for key in keys {
            access.add(key, frame: CGRect(x: 200, y: 200, width: 600, height: 400))
            try await manager.perform(.leftHalf, pid: 7, displays: [laptop])
        }
        let first = await manager.lastMove(of: keys[0])
        let second = await manager.lastMove(of: keys[1])
        XCTAssertNil(first)
        XCTAssertEqual(second?.frame, CGRect(x: 200, y: 200, width: 600, height: 400))
    }

    func testRestoreAfterItsDisplayWasRemovedCentersOnAnotherDisplay() async throws {
        let external = WindowDisplay(id: "external", name: "External", frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                     visibleFrame: CGRect(x: 1440, y: 25, width: 1920, height: 1055))
        let access = FixtureWindowAccess()
        let original = CGRect(x: 1600, y: 200, width: 800, height: 500)
        access.add(key, frame: original)
        let manager = WindowManager(access: access)
        try await manager.perform(.leftHalf, pid: 7, displays: [laptop, external])
        XCTAssertEqual(access.windows[key]?.frame, CGRect(x: 1440, y: 25, width: 960, height: 1055))
        try await manager.perform(.restore, pid: 7, displays: [laptop])
        XCTAssertEqual(access.windows[key]?.frame, CGRect(x: 320, y: 212.5, width: 800, height: 500))
    }

    func testMinimizeAndFullScreenToggleWriteOnlyTheirAttribute() async throws {
        let access = FixtureWindowAccess()
        access.add(key, frame: CGRect(x: 200, y: 200, width: 600, height: 400))
        let manager = WindowManager(access: access)
        try await manager.perform(.minimize, pid: 7, displays: [laptop])
        XCTAssertEqual(access.writes, [.minimized(key, true)])
        access.writes = []
        try await manager.perform(.toggleFullScreen, pid: 7, displays: [laptop])
        try await manager.perform(.toggleFullScreen, pid: 7, displays: [laptop])
        XCTAssertEqual(access.writes, [.fullScreen(key, true), .fullScreen(key, false)])
    }

    func testRepeatedLeftHalfCyclesWhenCycleSizesIsOn() async throws {
        let access = FixtureWindowAccess()
        access.add(key, frame: CGRect(x: 200, y: 200, width: 600, height: 400))
        let manager = WindowManager(access: access)
        let options = WindowLayoutOptions(cycleSizes: true)
        for width: CGFloat in [720, 960, 480, 720] {
            try await manager.perform(.leftHalf, pid: 7, displays: [laptop], options: options)
            XCTAssertEqual(access.windows[key]?.frame, CGRect(x: 0, y: 25, width: width, height: 875))
        }
        // Another half starts at ½ again.
        try await manager.perform(.rightHalf, pid: 7, displays: [laptop], options: options)
        XCTAssertEqual(access.windows[key]?.frame, CGRect(x: 720, y: 25, width: 720, height: 875))
        // A window the user moved since starts at ½ too.
        try await manager.perform(.rightHalf, pid: 7, displays: [laptop], options: options)
        let twoThirds = try XCTUnwrap(access.windows[key]?.frame)
        XCTAssertTrue(WindowGeometry.close(twoThirds, CGRect(x: 480, y: 25, width: 960, height: 875)), "\(twoThirds)")
        access.windows[key]?.frame = CGRect(x: 400, y: 25, width: 960, height: 875)
        try await manager.perform(.rightHalf, pid: 7, displays: [laptop], options: options)
        XCTAssertEqual(access.windows[key]?.frame, CGRect(x: 720, y: 25, width: 720, height: 875))
    }

    func testRepeatedLeftHalfIsTodaysRepeatWhenCycleSizesIsOff() async throws {
        for options in [WindowLayoutOptions.legacy, WindowLayoutOptions(gap: 10, portraitThirds: true)] {
            let access = FixtureWindowAccess()
            access.add(key, frame: CGRect(x: 200, y: 200, width: 600, height: 400))
            let manager = WindowManager(access: access)
            try await manager.perform(.leftHalf, pid: 7, displays: [laptop], options: options)
            let placed = access.windows[key]?.frame
            access.writes = []
            try await manager.perform(.leftHalf, pid: 7, displays: [laptop], options: options)
            XCTAssertEqual(access.writes, [])
            XCTAssertEqual(access.windows[key]?.frame, placed)
        }
    }

    func testRestoreAfterCyclingReturnsToTheFrameBeforeTheFirstPress() async throws {
        let options = WindowLayoutOptions(cycleSizes: true)
        // An app with a minimum width wider than ½ and ⅓ still cycles, and still restores.
        for minimum in [nil, CGSize(width: 800, height: 100)] {
            let access = FixtureWindowAccess()
            let original = CGRect(x: 200, y: 200, width: 900, height: 600)
            access.add(key, frame: original, minimumSize: minimum)
            let manager = WindowManager(access: access)
            var widths: [CGFloat] = []
            for _ in 0..<3 {
                try await manager.perform(.leftHalf, pid: 7, displays: [laptop], options: options)
                widths.append(try XCTUnwrap(access.windows[key]?.frame?.width))
            }
            XCTAssertEqual(widths, minimum == nil ? [720, 960, 480] : [800, 960, 800])
            let last = await manager.lastMove(of: key)
            XCTAssertEqual(last?.frame, original)
            XCTAssertEqual(last?.action, .leftHalf)
            XCTAssertEqual(last?.step, 2)
            try await manager.perform(.restore, pid: 7, displays: [laptop], options: options)
            XCTAssertEqual(access.windows[key]?.frame, original)
        }
    }
}
