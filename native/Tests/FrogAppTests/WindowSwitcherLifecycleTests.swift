import XCTest
import CoreGraphics
@testable import FrogApp

@MainActor
final class WindowSwitcherLifecycleTests: XCTestCase {
    func testInactiveSessionRetiresInputAndActivationAndCannotRearmFromLateTimeout() throws {
        let fixture = InputLifecycleFixture()
        let lifecycle = fixture.lifecycle(active: true)
        lifecycle.configure(enabled: true, suspended: false)
        let old = try XCTUnwrap(fixture.input)
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        event.flags = .maskCommand
        _ = old.receive(type: .keyDown, event: event)
        let session = try XCTUnwrap(old.state.sessionID)
        let activation = UUID()
        XCTAssertTrue(old.finish(session: session, activating: activation))
        lifecycle.sessionChanged(active: false)
        XCTAssertEqual(fixture.stops, 1)
        XCTAssertFalse(old.isActivationPending(activation))
        XCTAssertNotNil(old.receive(type: .tapDisabledByTimeout, event: event))
        XCTAssertNotNil(old.receive(type: .keyDown, event: event))
        XCTAssertFalse(old.state.active)
        lifecycle.sessionChanged(active: true)
        lifecycle.sessionChanged(active: true)
        lifecycle.wake()
        XCTAssertEqual(fixture.starts, 2, "Resume creates one replacement input service")
    }

    func testWakeRepairsUnhealthyHandleButNeverStartsDisabledOrSuspendedInput() {
        let fixture = InputLifecycleFixture()
        let lifecycle = fixture.lifecycle(active: true)
        lifecycle.configure(enabled: true, suspended: false)
        fixture.healthy = false
        lifecycle.wake()
        XCTAssertEqual(fixture.starts, 2)
        XCTAssertEqual(fixture.stops, 1)
        lifecycle.configure(enabled: false, suspended: false)
        lifecycle.sessionChanged(active: false)
        lifecycle.sessionChanged(active: true)
        lifecycle.wake()
        XCTAssertEqual(fixture.starts, 2)
        lifecycle.configure(enabled: true, suspended: true)
        lifecycle.wake()
        XCTAssertEqual(fixture.starts, 2)
        lifecycle.configure(enabled: true, suspended: false)
        XCTAssertEqual(fixture.starts, 3)
        lifecycle.stop()
        lifecycle.wake()
        XCTAssertEqual(fixture.starts, 3)
    }

    func testLaunchInInactiveSessionWaitsForActivation() {
        let fixture = InputLifecycleFixture()
        let lifecycle = fixture.lifecycle(active: false)
        lifecycle.configure(enabled: true, suspended: false)
        lifecycle.wake()
        XCTAssertEqual(fixture.starts, 0)
        lifecycle.sessionChanged(active: true)
        XCTAssertEqual(fixture.starts, 1)
    }
}

@MainActor
private final class InputLifecycleFixture {
    var starts = 0
    var stops = 0
    var healthy = true
    var input: WindowSwitchInput?
    func lifecycle(active: Bool) -> WindowSwitcherInputLifecycle {
        WindowSwitcherInputLifecycle(active: active, trusted: { true }, healthy: { self.healthy }, start: {
            self.starts += 1; self.healthy = true
            self.input = WindowSwitchInput { _ in }
            return true
        }, stop: {
            self.stops += 1; self.input?.stop(); self.input = nil
        }, statusChanged: { _, _ in })
    }
}
