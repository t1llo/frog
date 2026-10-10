import XCTest
@testable import FrogApp

@MainActor
final class DictationDeliveryTests: XCTestCase {
    func testCancelledInsertionCannotFinishOrCancelNewerRecording() async {
        let gate = DeliveryGate()
        var token = 1, completions = 0, issues = 0, successes = 0
        let task = Task {
            try await DictationDelivery.finish(isCurrent: { token == 1 }, paste: { await gate.wait() }, onIssue: { _ in issues += 1 }, onSuccess: { successes += 1 }) { _ in completions += 1; token = 0 }
        }
        await gate.waitUntilStarted()
        task.cancel(); token = 2
        await gate.resume()
        do { try await task.value; XCTFail("Cancelled delivery must throw") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(token, 2)
        XCTAssertEqual(completions, 0); XCTAssertEqual(issues, 0)
        XCTAssertEqual(successes, 0)
    }
    func testChangedGenerationRejectsNoncooperativeInsertion() async {
        let gate = DeliveryGate()
        var current = true, completed = false, succeeded = false
        let task = Task { try await DictationDelivery.finish(isCurrent: { current }, paste: { await gate.wait() }, onIssue: { _ in }, onSuccess: { succeeded = true }) { _ in completed = true } }
        await gate.waitUntilStarted(); current = false; await gate.resume()
        do { try await task.value; XCTFail("Stale delivery must throw") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(completed)
        XCTAssertFalse(succeeded)
    }
    func testCopyOnlyCompletesWithoutInsertion() async throws {
        var result = ""
        try await DictationDelivery.finish(isCurrent: { true }, paste: nil, onIssue: { _ in XCTFail() }) { result = $0 }
        XCTAssertEqual(result, "Copied")
    }
    func testSuccessCallbackCannotFinalizeANewerRecording() async throws {
        var token = 1, completions = 0, successes = 0
        try await DictationDelivery.finish(isCurrent: { token == 1 }, paste: nil, onIssue: { _ in XCTFail() }, onSuccess: {
            successes += 1; token = 2
        }) { _ in completions += 1; token = 0 }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(token, 2)
    }
}

private actor DeliveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func waitUntilStarted() async { while continuation == nil { await Task.yield() } }
    func resume() { continuation?.resume(); continuation = nil }
}
