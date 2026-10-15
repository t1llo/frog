import XCTest
import FrogCore
@testable import FrogApp

/// The layout picker's moves and previews, through fixture windows and without a panel.
@MainActor final class WindowLayoutControllerTests: XCTestCase {
    /// A 1440×900 display with a 25 pt menu bar.
    private let laptop = WindowDisplay(id: "laptop", name: "Built-in Display", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                       visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875))
    private let key = WindowKey(pid: 42, number: 1)
    private let original = CGRect(x: 200, y: 200, width: 600, height: 400)

    private func configuration(windows: Bool = true, picker: Bool, cycleSizes: Bool = false) -> Configuration {
        var configuration = Configuration()
        configuration.preferences.ensureToolkit()
        configuration.preferences.setFeature(.windows, enabled: windows)
        var settings = WindowPreferences()
        settings.layoutPicker = picker
        settings.cycleSizes = cycleSizes
        configuration.preferences.toolkit?.windows = settings
        return configuration
    }

    private func controller(_ access: FixtureWindowAccess) -> WindowLayoutController {
        let laptop = laptop
        return WindowLayoutController(manager: WindowManager(access: access), access: access, displays: { [laptop] },
                                      readMacOS: { MacWindowManagerSettings() })
    }

    func testPickerApplyMovesTheTargetWindowThroughTheAccess() async {
        let access = FixtureWindowAccess()
        access.add(key, frame: original)
        let controller = controller(access)
        // Inactive, so nothing is registered or watched; a move still runs.
        controller.configure(configuration(picker: true, cycleSizes: true), active: false)
        var uses: [ActivityToolKind] = []
        controller.onToolUse = { uses.append($0) }
        await controller.perform(.rightHalf, pid: 42).value
        let origin = CGPoint(x: 720, y: 25)
        XCTAssertEqual(access.writes, [.position(key, origin), .size(key, CGSize(width: 720, height: 875)), .position(key, origin)])
        XCTAssertEqual(uses, [.windowCommand])

        access.writes = []
        await controller.perform(.rightHalf, pid: 42).value
        XCTAssertEqual(access.writes, [], "A picker press never cycles the half")
    }

    func testPreviewReadsButNeverWrites() async throws {
        let access = FixtureWindowAccess()
        access.add(key, frame: original)
        let manager = WindowManager(access: access)
        let rightHalf = await manager.preview(.rightHalf, pid: 42, displays: [laptop])
        XCTAssertEqual(rightHalf, CGRect(x: 720, y: 25, width: 720, height: 875))
        let noHistory = await manager.preview(.restore, pid: 42, displays: [laptop])
        XCTAssertNil(noHistory, "Restore shows nothing before a move")
        XCTAssertEqual(access.writes, [])

        try await manager.perform(.leftHalf, pid: 42, displays: [laptop])
        access.writes = []
        let restore = await manager.preview(.restore, pid: 42, displays: [laptop])
        XCTAssertEqual(restore, original)
        XCTAssertEqual(access.windows[key]?.frame, CGRect(x: 0, y: 25, width: 720, height: 875))

        access.windows[key]?.state.fullScreen = true
        let fullScreen = await manager.preview(.leftHalf, pid: 42, displays: [laptop])
        XCTAssertNil(fullScreen)
        let missing = await manager.preview(.leftHalf, pid: 7, displays: [laptop])
        XCTAssertNil(missing)
        XCTAssertEqual(access.writes, [])
    }

    func testPickerCommandDoesNothingWhileItsSwitchIsOff() {
        let controller = controller(FixtureWindowAccess())
        defer { controller.stop() }
        controller.configure(configuration(picker: false), active: true)
        XCTAssertTrue(controller.running)
        XCTAssertFalse(controller.pickerAvailable)
        XCTAssertFalse(controller.trackingTarget, "Nothing watches app activation while the picker is off")
        controller.handle(.layoutPicker, pressed: true)
        XCTAssertFalse(controller.pickerVisible)

        controller.configure(configuration(picker: true), active: true)
        XCTAssertTrue(controller.pickerAvailable)
        XCTAssertTrue(controller.trackingTarget)
        controller.configure(configuration(windows: false, picker: true), active: true)
        XCTAssertFalse(controller.pickerAvailable)
        XCTAssertFalse(controller.trackingTarget)
        controller.configure(configuration(picker: true), active: false)
        XCTAssertFalse(controller.trackingTarget)
    }

    func testRestoreAfterPickerReturnsToThePreviousFrame() async {
        let access = FixtureWindowAccess()
        access.add(key, frame: original)
        let controller = controller(access)
        controller.configure(configuration(picker: true), active: false)
        await controller.perform(.rightHalf, pid: 42).value
        XCTAssertEqual(access.windows[key]?.frame, CGRect(x: 720, y: 25, width: 720, height: 875))
        await controller.perform(.restore, pid: 42).value
        XCTAssertEqual(access.windows[key]?.frame, original)
    }

    func testPreviewFramesTurnIntoCocoaCoordinates() {
        XCTAssertEqual(WindowPreviewPanel.cocoaRect(CGRect(x: 0, y: 25, width: 720, height: 875), primaryTop: 900),
                       CGRect(x: 0, y: 0, width: 720, height: 875))
        // A display above the primary one has negative Accessibility y.
        XCTAssertEqual(WindowPreviewPanel.cocoaRect(CGRect(x: 100, y: -500, width: 400, height: 300), primaryTop: 900),
                       CGRect(x: 100, y: 1100, width: 400, height: 300))
    }
}
