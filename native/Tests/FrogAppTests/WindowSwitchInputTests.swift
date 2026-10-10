import XCTest
import CoreGraphics
@testable import FrogApp

final class WindowSwitchInputTests: XCTestCase {
    func testMouseClickInvalidatesActivationBeforeUIReceivesTheMessage() throws {
        let messages = Messages()
        let input = WindowSwitchInput { messages.append($0) }
        let activation = UUID()
        try armActivation(activation, input: input)
        let mouse = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                         mouseCursorPosition: .zero, mouseButton: .left))
        XCTAssertNotNil(input.receive(type: .leftMouseDown, event: mouse))
        XCTAssertFalse(input.isActivationPending(activation), "AX must observe cancellation even while the UI queue is busy")
        guard case .mouse(_, _, let cancelled) = messages.values.last else { return XCTFail("Expected mouse cancellation") }
        XCTAssertEqual(cancelled, activation)
    }

    func testTimeoutCancelsPendingActivationAndStoppedInputCannotReenableTap() throws {
        let messages = Messages()
        let reenables = Rearms()
        let input = WindowSwitchInput(reenableTap: { reenables.increment() }) { messages.append($0) }
        let activation = UUID()
        try armActivation(activation, input: input)
        let event = try key(48, flags: .maskCommand)
        _ = input.receive(type: .tapDisabledByTimeout, event: event)
        XCTAssertFalse(input.isActivationPending(activation))
        guard case .reset(_, let cancelled) = messages.values.last else { return XCTFail("Expected timeout reset") }
        XCTAssertEqual(cancelled, activation)
        XCTAssertEqual(reenables.count, 1)
        input.stop()
        _ = input.receive(type: .tapDisabledByTimeout, event: event)
        _ = input.receive(type: .tapDisabledByUserInput, event: event)
        XCTAssertEqual(reenables.count, 1)
    }

    func testTypingDefersBackgroundScansUntilAQuietInterval() throws {
        let input = WindowSwitchInput { _ in }
        XCTAssertFalse(input.shouldDeferBackgroundWork())
        _ = input.receive(type: .keyDown, event: try key(0))
        XCTAssertTrue(input.shouldDeferBackgroundWork())
        XCTAssertFalse(input.shouldDeferBackgroundWork(at: .now.advanced(by: .seconds(2))))
    }

    func testOrdinaryTypingPassesThroughWithoutSchedulingAnyUIWork() throws {
        let messages = Messages()
        let input = WindowSwitchInput { messages.append($0) }
        for code in [UInt16(0), 8, 9, 48, 51, 53, 123] {
            for flags in [CGEventFlags(), .maskCommand, .maskControl, .maskAlternate] where !(code == 48 && flags == .maskCommand) {
                for down in [true, false] {
                    let event = try key(code, down: down, flags: flags)
                    XCTAssertTrue(input.receive(type: down ? .keyDown : .keyUp, event: event) != nil)
                }
            }
        }
        XCTAssertEqual(messages.values.count, 0)
    }

    func testSwitcherSearchCommitAndKeyUpsStayPairedAcrossTheThreadBoundary() throws {
        let messages = Messages()
        let input = WindowSwitchInput { messages.append($0) }
        XCTAssertTrue(input.receive(type: .keyDown, event: try key(48, flags: .maskCommand)) == nil)
        let session = try XCTUnwrap(input.state.sessionID)
        let search = try key(0, flags: .maskCommand)
        let text = Array("é".utf16)
        search.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
        XCTAssertTrue(input.receive(type: .keyDown, event: search) == nil)
        XCTAssertTrue(input.receive(type: .flagsChanged, event: try key(55)) != nil)
        let actions = messages.values.compactMap { message -> WindowSwitchKeyRouter.Action? in
            if case .key(let result, _) = message { return result.action }; return nil
        }
        XCTAssertEqual(actions, [.begin(backwards: false), .search("é"), .commit])
        input.finish(session: session)
        XCTAssertTrue(input.receive(type: .keyUp, event: try key(48, down: false)) == nil)
        XCTAssertTrue(input.receive(type: .keyUp, event: try key(0, down: false)) == nil)
        XCTAssertTrue(input.receive(type: .keyDown, event: try key(0)) != nil)
    }

    func testTypingCancelsOnlyTheActivationThatWasPendingAtThatEvent() throws {
        let messages = Messages()
        let input = WindowSwitchInput { messages.append($0) }
        let old = UUID(), next = UUID()
        try armActivation(old, input: input)
        XCTAssertTrue(input.receive(type: .keyDown, event: try key(0)) != nil)
        let firstCancellation = messages.values.last
        try armActivation(next, input: input)
        guard case .key(_, let cancelled) = firstCancellation else { return XCTFail("Expected an activation cancellation") }
        XCTAssertEqual(cancelled, old)
        XCTAssertTrue(input.receive(type: .keyDown, event: try key(1)) != nil)
        guard case .key(_, let second) = messages.values.last else { return XCTFail("Expected a second activation cancellation") }
        XCTAssertEqual(second, next)
        XCTAssertFalse(input.isActivationPending(next))
    }

    func testTypingBeforeUICommitCannotArmALateWindowActivation() throws {
        let input = WindowSwitchInput { _ in }
        _ = input.receive(type: .keyDown, event: try key(48, flags: .maskCommand))
        let session = try XCTUnwrap(input.state.sessionID)
        _ = input.receive(type: .flagsChanged, event: try key(55))
        _ = input.receive(type: .keyDown, event: try key(0))
        let activation = UUID()
        XCTAssertFalse(input.finish(session: session, activating: activation))
        XCTAssertFalse(input.isActivationPending(activation))
    }

    func testTimeoutAndStopRestoreInputAndStaleCompletionCannotResetANewChord() throws {
        let input = WindowSwitchInput { _ in }
        let tab = try key(48, flags: .maskCommand)
        _ = input.receive(type: .keyDown, event: tab)
        let old = try XCTUnwrap(input.state.sessionID)
        _ = input.receive(type: .tapDisabledByTimeout, event: tab)
        XCTAssertFalse(input.state.active)
        _ = input.receive(type: .keyDown, event: tab)
        input.finish(session: old)
        XCTAssertTrue(input.state.active)
        input.stop()
        XCTAssertTrue(input.receive(type: .keyDown, event: tab) != nil)
        XCTAssertFalse(input.state.active)
    }

    private func key(_ code: CGKeyCode, down: Bool = true, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        event.flags = flags
        return event
    }

    private func armActivation(_ id: UUID, input: WindowSwitchInput) throws {
        _ = input.receive(type: .keyDown, event: try key(48, flags: .maskCommand))
        let session = try XCTUnwrap(input.state.sessionID)
        _ = input.receive(type: .flagsChanged, event: try key(55))
        XCTAssertTrue(input.finish(session: session, activating: id))
        _ = input.receive(type: .keyUp, event: try key(48, down: false))
    }

    private final class Messages: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [WindowSwitchInput.Event] = []
        var values: [WindowSwitchInput.Event] { lock.withLock { events } }
        func append(_ event: WindowSwitchInput.Event) { lock.withLock { events.append(event) } }
    }

    private final class Rearms: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func increment() { lock.withLock { value += 1 } }
    }
}
