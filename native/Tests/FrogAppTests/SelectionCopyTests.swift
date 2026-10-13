import AppKit
import XCTest
@testable import FrogApp

@MainActor
final class SelectionCopyTests: XCTestCase {
    func testCopyWaitsForTextAfterAppClearsClipboard() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("previous clipboard", forType: .string)
        let text = try await FreshSelectionCopy.read(pasteboard: board) {
            board.clearContents()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                board.setString("selected text", forType: .string)
            }
        }
        XCTAssertEqual(text, "selected text")
        XCTAssertEqual(board.string(forType: .string), "previous clipboard")
    }

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
                _ = try await FreshSelectionCopy.read(pasteboard: board, attempts: 1) {
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

    /// A Copy request that the app has not answered when `read` gives up.
    private func unansweredCopy(on board: NSPasteboard, lateCopy: @escaping (String) -> Bool) async {
        do {
            _ = try await FreshSelectionCopy.read(pasteboard: board, attempts: 1, lateCopy: lateCopy) {}
            XCTFail("Accepted a clipboard that did not change")
        } catch {}
    }

    func testCopyAnsweredAfterTheWaitIsUndone() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("previous clipboard", forType: .string)
        board.setData(Data([1, 2, 3]), forType: .rtf)
        await unansweredCopy(on: board) { $0 == "selected text" }
        XCTAssertEqual(board.string(forType: .string), "previous clipboard")

        board.clearContents(); board.setString("selected text", forType: .string)
        await FreshSelectionCopy.lateCopyWatch?.value

        XCTAssertEqual(board.string(forType: .string), "previous clipboard")
        XCTAssertEqual(board.data(forType: .rtf), Data([1, 2, 3]))
        XCTAssertTrue(ClipboardHistoryCaptureGate.shared.ignores(name: board.name, count: board.changeCount),
                      "Putting the clipboard back must not look like a new copy to clipboard history")
    }

    func testLateCopyThatClearsTheClipboardBeforeWritingIsUndone() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("previous clipboard", forType: .string)
        await unansweredCopy(on: board) { $0 == "selected text" }

        board.clearContents()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { board.setString("selected text", forType: .string) }
        await FreshSelectionCopy.lateCopyWatch?.value

        XCTAssertEqual(board.string(forType: .string), "previous clipboard")
    }

    func testClipboardChangeThatIsNotTheLateCopyIsLeftAlone() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("previous clipboard", forType: .string)
        var asked: [String] = []
        await unansweredCopy(on: board) { asked.append($0); return false }

        board.clearContents(); board.setString("copied by the user", forType: .string)
        await FreshSelectionCopy.lateCopyWatch?.value

        XCTAssertEqual(asked, ["copied by the user"])
        XCTAssertEqual(board.string(forType: .string), "copied by the user")
    }

    func testNextCopyEndsTheWatchForTheEarlierOne() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("previous clipboard", forType: .string)
        var asked = 0
        await unansweredCopy(on: board) { _ in asked += 1; return true }
        let earlier = FreshSelectionCopy.lateCopyWatch

        let text = try await FreshSelectionCopy.read(pasteboard: board) {
            board.clearContents(); board.setString("second selection", forType: .string)
        }
        await earlier?.value

        XCTAssertEqual(text, "second selection")
        XCTAssertEqual(asked, 0, "The earlier watch must not judge the answer to a newer Copy")
        XCTAssertEqual(board.string(forType: .string), "previous clipboard")
    }

    func testCopyThatWasNeverRequestedIsNotWatchedFor() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("previous clipboard", forType: .string)
        struct Refused: Error {}
        do {
            _ = try await FreshSelectionCopy.read(pasteboard: board, lateCopy: { _ in true }) { throw Refused() }
            XCTFail("Expected the refusal")
        } catch { XCTAssertTrue(error is Refused) }
        XCTAssertNil(FreshSelectionCopy.lateCopyWatch)
    }

    func testResultIsPutBackBeforePasteWhenTheClipboardHoldsSomethingElse() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original selection", forType: .string)
        try ClipboardSelection.putBack("result", on: board)
        XCTAssertEqual(board.string(forType: .string), "result")

        // A clipboard that already holds the result is not written a second time.
        let count = board.changeCount
        try ClipboardSelection.putBack("result", on: board)
        XCTAssertEqual(board.changeCount, count)
    }
}
