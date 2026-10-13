import AppKit
import XCTest
@testable import FrogApp

/// The automatic watch of the store against a pasteboard of its own. The test stands in
/// for the half-second pause, so each look happens when the test says so.
@MainActor
final class ClipboardHistoryPollingTests: XCTestCase {
    func testUnchangedClipboardIsWatchedWithoutTheMainActor() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let pauses = PollPauses()
        let history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate(), pollPause: { try await pauses.pause() })
        history.configure(enabled: true)
        defer { history.configure(enabled: false) }
        guard await pauses.started() else { return XCTFail("The watch did not start") }

        pasteboard.clearContents(); pasteboard.setString("Copied while watched", forType: .string)
        guard await pauses.look() else { return XCTFail("The watch did not look") }
        XCTAssertEqual(history.entries.map(\.text), ["Copied while watched"])

        // Nothing is copied from here on. Frog is busy with something else, and the
        // watch has no reason to wait for it.
        XCTAssertTrue(pauses.lookWhileTheMainActorIsBusy(times: 3), "Looking at a clipboard that did not change must not need the main actor")

        pasteboard.clearContents(); pasteboard.setString("Copied afterwards", forType: .string)
        guard await pauses.look() else { return XCTFail("The watch did not look") }
        XCTAssertEqual(history.entries.map(\.text), ["Copied afterwards", "Copied while watched"])
    }

    func testWatchKeepsAskingForTextThatArrivesAfterItsCopy() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let pauses = PollPauses()
        let history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate(), pollPause: { try await pauses.pause() })
        history.configure(enabled: true)
        defer { history.configure(enabled: false) }
        guard await pauses.started() else { return XCTFail("The watch did not start") }

        // An application that announces text first and supplies it a moment later.
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("", forType: .string)
        let count = pasteboard.changeCount
        guard await pauses.look() else { return XCTFail("The watch did not look") }
        XCTAssertTrue(history.entries.isEmpty)
        pasteboard.setString("Delayed text", forType: .string)
        XCTAssertEqual(pasteboard.changeCount, count, "The text arrives without another change of the clipboard")
        guard await pauses.look() else { return XCTFail("The watch did not look") }
        XCTAssertEqual(history.entries.map(\.text), ["Delayed text"])

        // Text that never arrives is given up after the third look, and the watch rests again.
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("", forType: .string)
        for _ in 0..<3 { guard await pauses.look() else { return XCTFail("The watch did not look") } }
        XCTAssertTrue(pauses.lookWhileTheMainActorIsBusy(times: 2))
        XCTAssertEqual(history.entries.map(\.text), ["Delayed text"])
    }

    func testWatchLeavesWhatFrogWroteAndWhatWasRemovedAlone() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let pauses = PollPauses()
        let history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate(), pollPause: { try await pauses.pause() })
        history.configure(enabled: true)
        defer { history.configure(enabled: false) }
        guard await pauses.started() else { return XCTFail("The watch did not start") }

        for text in ["Older", "Newer"] {
            pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
            guard await pauses.look() else { return XCTFail("The watch did not look") }
        }
        let older = try XCTUnwrap(history.entries.last)
        XCTAssertTrue(history.copy(older))
        let ids = history.entries.map(\.id)
        guard await pauses.look() else { return XCTFail("The watch did not look") }
        XCTAssertEqual(history.entries.map(\.id), ids, "An item copied from history is not a new copy")
        XCTAssertEqual(history.entries.map(\.text), ["Older", "Newer"])

        history.clear()
        guard await pauses.look() else { return XCTFail("The watch did not look") }
        XCTAssertTrue(history.entries.isEmpty, "What is still on the clipboard does not come back after Clear")
        XCTAssertTrue(pauses.lookWhileTheMainActorIsBusy(times: 2))

        pasteboard.clearContents(); pasteboard.setString("Copied after Clear", forType: .string)
        guard await pauses.look() else { return XCTFail("The watch did not look") }
        XCTAssertEqual(history.entries.map(\.text), ["Copied after Clear"])
    }
}

/// Hands the watch its pauses one at a time and counts how often it came back for one.
private final class PollPauses: @unchecked Sendable {
    private let lock = NSLock()
    private var arrivals = 0
    private let permits: AsyncStream<Void>
    private let permit: AsyncStream<Void>.Continuation

    init() { (permits, permit) = AsyncStream<Void>.makeStream() }

    /// What the store sleeps with: it ends when the test allows the next look.
    func pause() async throws {
        lock.withLock { arrivals += 1 }
        var iterator = permits.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
    }

    private var count: Int { lock.withLock { arrivals } }

    /// The watch has reached its first pause and has not looked at anything yet.
    func started() async -> Bool { await reaches(1) }

    /// One look, with the main actor free to answer. Returns once the watch pauses again.
    func look() async -> Bool {
        let target = count + 1
        permit.yield()
        return await reaches(target)
    }

    /// Looks while the calling thread, the main one, is held and can serve nobody.
    func lookWhileTheMainActorIsBusy(times: Int) -> Bool {
        let target = count + times
        for _ in 0..<times { permit.yield() }
        let deadline = Date().addingTimeInterval(10)
        while count < target {
            if Date() > deadline { return false }
            usleep(2_000)
        }
        return true
    }

    private func reaches(_ target: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while count < target {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }
}
