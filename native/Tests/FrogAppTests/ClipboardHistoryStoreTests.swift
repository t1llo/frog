import AppKit
import Combine
import XCTest
@testable import FrogApp

/// The store's list against a pasteboard of its own, without a panel.
@MainActor
final class ClipboardHistoryStoreTests: XCTestCase {
    func testEachCopyChangesTheListOnce() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate())
        history.configure(enabled: true, automaticallyPoll: false)
        defer { history.configure(enabled: false) }
        var changes = 0
        let subscription = history.$entries.dropFirst().sink { _ in changes += 1 }
        defer { subscription.cancel() }

        // An open panel searches the whole list again on every change of it.
        history.recordCopiedText("Fixture 0")
        XCTAssertEqual(changes, 1, "A new item")
        history.recordCopiedText("Fixture 0")
        XCTAssertEqual(changes, 2, "An item copied again moves to the top in one change")
        for index in 1..<ClipboardHistoryStore.capacity { history.recordCopiedText("Fixture \(index)") }
        changes = 0
        history.recordCopiedText("Fixture beyond")
        XCTAssertEqual(changes, 1, "The oldest item gives way in the same change")
        XCTAssertEqual(history.entries.count, ClipboardHistoryStore.capacity)
        XCTAssertEqual(history.entries.first?.text, "Fixture beyond")
        XCTAssertEqual(history.entries.last?.text, "Fixture 1")
    }
}
