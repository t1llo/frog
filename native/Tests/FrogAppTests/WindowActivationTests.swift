import AppKit
import XCTest
@testable import FrogApp

@MainActor
final class WindowActivationTests: XCTestCase {
    func testInvalidatedSelectionNeverRequestsFocus() async {
        let result = await WindowActivation.perform(raise: { XCTFail("Stale raise"); return true },
            request: { XCTFail("Stale activation"); return true }, bringForward: { XCTFail("Stale fallback"); return true },
            isFrontmost: { false }, isCurrent: { false }, pause: {})
        XCTAssertFalse(result)
    }

    func testInvalidationWhileRaisingCannotTriggerFallbackOrSecondRaise() async {
        var current = true
        var raises = 0
        let result = await WindowActivation.perform(raise: { raises += 1; current = false; return true },
            request: { true }, bringForward: { XCTFail("Stale fallback"); return true },
            isFrontmost: { false }, isCurrent: { current }, pause: {})
        XCTAssertFalse(result)
        XCTAssertEqual(raises, 1)
    }

    func testInputAfterTheAppWasAskedForStillRaisesTheChosenWindowButNothingAfterIt() async {
        var current = true
        var events: [String] = []
        // A keystroke arrives right after the app was asked to come forward: it comes all the same.
        let result = await WindowActivation.perform(raise: { events.append("raise"); return true },
            request: { events.append("request"); current = false; return true },
            bringForward: { events.append("forward"); return true }, isFrontmost: { false },
            isCurrent: { current }, raiseAfterRequest: { events.append("finish"); return true }, pause: {})
        XCTAssertFalse(result)
        XCTAssertEqual(events, ["request", "finish"], "The app must not arrive showing another window than the one chosen")

        // No request, nothing on its way: input still stops a raise in the app already in front.
        events = []; current = true
        let same = await WindowActivation.perform(raise: { events.append("raise"); return true },
            request: { events.append("request"); return true }, bringForward: { events.append("forward"); return true },
            isFrontmost: { true }, prepare: { current = false; return true }, isCurrent: { current },
            raiseAfterRequest: { events.append("finish"); return true }, pause: {})
        XCTAssertFalse(same)
        XCTAssertEqual(events, [])
    }

    func testCancellationWhileWaitingDoesNotRaiseAgain() async {
        var raises = 0
        let result = await WindowActivation.perform(raise: { raises += 1; return true }, request: { true }, bringForward: { true }, isFrontmost: { false }, pause: { throw CancellationError() })
        XCTAssertFalse(result)
        XCTAssertEqual(raises, 1)
    }
    func testExplicitChoiceCanReplaceAnotherForegroundApplication() async {
        var selectedIsFrontmost = false
        var raises = 0
        let result = await WindowActivation.perform(raise: { raises += 1; return true }, request: { true }, bringForward: {
            selectedIsFrontmost = true; return true
        }, isFrontmost: { selectedIsFrontmost }, pause: {})
        XCTAssertTrue(result)
        XCTAssertTrue(selectedIsFrontmost, "Raising inside a background app must not leave Terminal in front")
        XCTAssertEqual(raises, 2)
    }
    func testAcceptedActivationRequestIsNotProofOfForegroundOwnership() async {
        let result = await WindowActivation.perform(raise: { true }, request: { true }, bringForward: { false }, isFrontmost: { false }, pause: {})
        XCTAssertFalse(result)
    }
    func testAppStillReportedInFrontIsAskedForAgainWhileAnotherIsOnItsWay() async {
        var requests = 0
        var raises = 0
        // The app chosen a moment ago has not arrived; the one returned to must follow it.
        let result = await WindowActivation.perform(raise: { raises += 1; return true }, request: { requests += 1; return true },
            bringForward: { XCTFail("Unexpected fallback"); return false }, isFrontmost: { true },
            expectsAnother: { requests == 0 }, pause: {})
        XCTAssertTrue(result)
        XCTAssertEqual(requests, 1, "Without a request the app on its way would end up in front")
        XCTAssertEqual(raises, 1)
    }
    func testWindowRaisedBeforeItsAppArrivedIsNotReportedFailedWhenRaisingItAgainFails() async {
        var ticks = 0
        var raises = 0
        // The app arrives with the window raised in it; the raise that only settles it there goes unanswered.
        let result = await WindowActivation.perform(raise: { raises += 1; return raises == 1 }, request: { true },
            bringForward: { false }, isFrontmost: { ticks >= 1 }, pause: { ticks += 1 })
        XCTAssertTrue(result, "The switch went through; it must not be reported as failed")
        XCTAssertEqual(raises, 2)

        // An app that was asked for but never arrives is still a failure.
        let absent = await WindowActivation.perform(raise: { true }, request: { true }, bringForward: { false },
            isFrontmost: { false }, pause: {})
        XCTAssertFalse(absent)
    }
    func testRaiseThatItsBusyAppHasNotAnsweredYetIsTriedAgainButARefusalIsNot() async {
        let answers = RaiseAnswers([.cannotComplete, .cannotComplete, .success])
        var writer = WindowActivationExecutor.Writer()
        writer.isTrusted = { true }
        writer.reveal = { _, _, _ in true }
        writer.isWindow = { _ in true }
        writer.isMinimized = { _ in false }
        writer.raise = { _ in answers.next() }
        writer.makeMain = { _ in answers.note("main") }
        let target = WindowCatalog.Target(id: UUID(), pid: 10, element: AXUIElementCreateApplication(1010), windowID: 202)
        let raised = await WindowActivationExecutor(writer: writer).raise(target, isCurrent: { true })
        XCTAssertTrue(raised, "An app busy unhiding answers late; its window still comes forward")
        XCTAssertEqual(answers.events, ["raise", "raise", "raise", "main"])

        let refused = RaiseAnswers([.invalidUIElement, .success])
        writer.raise = { _ in refused.next() }
        writer.makeMain = { _ in refused.note("main") }
        let gone = await WindowActivationExecutor(writer: writer).raise(target, isCurrent: { true })
        XCTAssertFalse(gone)
        XCTAssertEqual(refused.events, ["raise"], "A window that is gone is not raised again")
    }
    func testWindowWhoseBusyAppHasNotSaidYetThatItIsOneIsAskedAgain() async {
        let trace = RaiseAnswers([.success])
        let checks = Script<Bool?>([nil, nil, true])
        var writer = WindowActivationExecutor.Writer()
        writer.isTrusted = { true }
        writer.reveal = { _, _, _ in true }
        writer.isWindow = { _ in trace.note("validate"); return checks.next() }
        writer.resolve = { _, _ in trace.note("resolve"); return nil }
        writer.isMinimized = { _ in false }
        writer.raise = { _ in trace.next() }
        writer.makeMain = { _ in trace.note("main") }
        let target = WindowCatalog.Target(id: UUID(), pid: 10, element: AXUIElementCreateApplication(1010), windowID: 202)
        let raised = await WindowActivationExecutor(writer: writer).raise(target, isCurrent: { true })
        XCTAssertTrue(raised, "An app busy coming forward answers late; its window still comes forward")
        XCTAssertEqual(trace.events, ["validate", "validate", "validate", "raise", "main"])

        // Waiting for that answer stops for input, also once the app was asked for.
        let unanswered = RaiseAnswers([.success])
        writer.isWindow = { _ in unanswered.note("validate"); return nil }
        writer.resolve = { _, _ in unanswered.note("resolve"); return nil }
        writer.raise = { _ in unanswered.next() }
        writer.makeMain = { _ in unanswered.note("main") }
        let executor = WindowActivationExecutor(writer: writer)
        _ = await executor.prepare(target, isCurrent: { true })
        let moved = await executor.raise(target, isCurrent: { false }, requested: true)
        XCTAssertFalse(moved)
        XCTAssertEqual(unanswered.events, ["validate"])
    }
    func testRaiseSentWithTheRequestIsNotTriedAgainOnceTheUserHasMovedOn() async {
        let answers = RaiseAnswers([.success])
        var writer = WindowActivationExecutor.Writer()
        writer.isTrusted = { true }
        writer.reveal = { _, _, _ in true }
        writer.isWindow = { _ in true }
        writer.isMinimized = { _ in false }
        writer.raise = { _ in answers.next() }
        writer.makeMain = { _ in answers.note("main") }
        let target = WindowCatalog.Target(id: UUID(), pid: 10, element: AXUIElementCreateApplication(1010), windowID: 202)
        // Another window was chosen or clicked right after the app was asked for.
        let executor = WindowActivationExecutor(writer: writer)
        _ = await executor.prepare(target, isCurrent: { true })
        let sent = await executor.raise(target, isCurrent: { false }, requested: true)
        XCTAssertTrue(sent, "The raise sent with the request still goes through")
        XCTAssertEqual(answers.events, ["raise", "main"])

        // Unanswered, it may still land; asking again a moment later would cover the window chosen since.
        let late = RaiseAnswers([.cannotComplete, .success])
        writer.raise = { _ in late.next() }
        writer.makeMain = { _ in late.note("main") }
        let busy = WindowActivationExecutor(writer: writer)
        _ = await busy.prepare(target, isCurrent: { true })
        let retried = await busy.raise(target, isCurrent: { false }, requested: true)
        XCTAssertFalse(retried)
        XCTAssertEqual(late.events, ["raise"])
    }
    func testRaisingTheWindowAgainOnceItsAppIsInFrontDoesNotLookForItsDesktopAgain() async {
        let trace = RaiseAnswers([.success])
        var writer = WindowActivationExecutor.Writer()
        writer.isTrusted = { true }
        writer.reveal = { _, _, _ in trace.note("space"); return true }
        writer.isWindow = { _ in trace.note("validate"); return true }
        writer.isMinimized = { _ in false }
        writer.raise = { _ in trace.next() }
        writer.makeMain = { _ in trace.note("main") }
        let moment = Moment()
        let executor = WindowActivationExecutor(writer: writer, now: { moment.now })
        let target = WindowCatalog.Target(id: UUID(), pid: 10, element: AXUIElementCreateApplication(1010), windowID: 202)
        let prepared = await executor.prepare(target, isCurrent: { true })
        let first = await executor.raise(target, isCurrent: { true })
        let second = await executor.raise(target, isCurrent: { true })
        XCTAssertTrue(prepared && first && second)
        XCTAssertEqual(trace.events, ["space", "validate", "raise", "main", "validate", "raise", "main"],
                       "The window raised a moment ago is on the Desktop in sight; only its handle is checked again")

        // Any later raise looks for the Desktop again: the window may have moved since.
        let later = await executor.raise(target, isCurrent: { true })
        XCTAssertTrue(later)
        XCTAssertEqual(trace.events.suffix(4), ["space", "validate", "raise", "main"])
        moment.advance(seconds: 3)
        _ = await executor.raise(target, isCurrent: { true })
        XCTAssertEqual(trace.events.suffix(4), ["space", "validate", "raise", "main"], "Nor is a raise a while ago a reason to skip it")
    }
    func testFinalRaiseWaitsForApplicationToBecomeFrontmost() async {
        var ticks = 0
        var finalRaiseTicks: [Int] = []
        let result = await WindowActivation.perform(raise: { finalRaiseTicks.append(ticks); return true }, request: { true }, bringForward: { true }, isFrontmost: { ticks >= 2 }, pause: { ticks += 1 })
        XCTAssertTrue(result)
        XCTAssertEqual(finalRaiseTicks, [0, 2])
    }
}

/// Answers a raise with the next scripted AX result, then with the last one.
private final class RaiseAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [AXError]
    private var recorded: [String] = []
    init(_ answers: [AXError]) { self.answers = answers }
    var events: [String] { lock.withLock { recorded } }
    func note(_ event: String) { lock.withLock { recorded.append(event) } }
    func next() -> AXError {
        lock.withLock {
            recorded.append("raise")
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }
}

/// Gives the next scripted answer, then the last one.
private final class Script<Answer>: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Answer]
    init(_ answers: [Answer]) { self.answers = answers }
    func next() -> Answer { lock.withLock { answers.count > 1 ? answers.removeFirst() : answers[0] } }
}

/// A clock that moves only when told to.
private final class Moment: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(seconds: Int) { lock.withLock { instant = instant.advanced(by: .seconds(seconds)) } }
}
