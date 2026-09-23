import AppKit
import XCTest
@testable import FrogApp

@MainActor
final class SelectionCopyTests: XCTestCase {
    func testStaleClipboardIsNeverAcceptedAsSelection() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("stale clipboard", forType: .string)
        do {
            _ = try await FreshSelectionCopy.read(pasteboard: board, attempts: 1) {}
            XCTFail("Accepted old clipboard content without a fresh Copy")
        } catch { XCTAssertEqual(board.string(forType: .string), "stale clipboard") }
    }

    func testFreshCopyReadsSelectionAndRestoresAllPreviousFormats() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old", forType: .string)
        board.setData(Data([1, 2, 3]), forType: .rtf)
        let text = try await FreshSelectionCopy.read(pasteboard: board) {
            board.clearContents(); board.setString("selected text", forType: .string)
        }
        XCTAssertEqual(text, "selected text")
        XCTAssertEqual(board.string(forType: .string), "old")
        XCTAssertEqual(board.data(forType: .rtf), Data([1, 2, 3]))
    }

    func testFreshNonTextCopyFailsAndRestoresClipboard() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old", forType: .string)
        do {
            _ = try await FreshSelectionCopy.read(pasteboard: board) {
                board.clearContents(); board.setData(Data([1]), forType: .png)
            }
            XCTFail("Expected non-text rejection")
        } catch { XCTAssertEqual(board.string(forType: .string), "old") }
    }

    func testCancellationWaitsForPendingCopyAndRestoresPreviousClipboard() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old", forType: .string)
        var requested = false
        let task = Task {
            try await FreshSelectionCopy.read(pasteboard: board) {
                requested = true
            }
        }
        while !requested { await Task.yield() }
        task.cancel()
        board.clearContents(); board.setString("delayed copied selection", forType: .string)
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(board.string(forType: .string), "old")
    }
}
