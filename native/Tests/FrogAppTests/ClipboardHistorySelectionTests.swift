import XCTest
@testable import FrogApp

/// Which row the clipboard panel's Return acts on, decided on its state alone. No panel is shown.
@MainActor
final class ClipboardHistorySelectionTests: XCTestCase {
    private func entries(_ texts: [String]) -> [ClipboardHistoryEntry] { texts.map { ClipboardHistoryEntry(text: $0) } }

    func testArrowsMoveTheSelectionAndStopAtTheEnds() {
        let state = ClipboardHistoryPanelState()
        state.update(entries(["first", "second", "third"]))
        state.moveSelection(by: 1); state.moveSelection(by: 1)
        XCTAssertEqual(state.selected?.text, "third")
        state.moveSelection(by: 1)
        XCTAssertEqual(state.selected?.text, "third", "Down on the last row stays there")
        state.moveSelection(by: -1); state.moveSelection(by: -1); state.moveSelection(by: -1)
        XCTAssertEqual(state.selected?.text, "first", "Up on the first row stays there")
        XCTAssertFalse(state.selectionFromPointer, "The keys scroll the list to the selection")
    }

    func testANewCopyWhileOpenKeepsTheHighlightedItemSelected() {
        let state = ClipboardHistoryPanelState()
        let kept = entries(["newest", "middle", "older"])
        state.update(kept)
        state.moveSelection(by: 2)
        XCTAssertEqual(state.selected?.text, "older")
        state.update(entries(["just copied"]) + kept)
        XCTAssertEqual(state.selectedIndex, 3)
        XCTAssertEqual(state.selected?.text, "older", "Return pastes the row that was highlighted, not the one now at its place")
    }

    func testAnItemCopiedAgainWhileOpenStaysSelected() {
        let state = ClipboardHistoryPanelState()
        let kept = entries(["newest", "middle", "older"])
        state.update(kept)
        state.moveSelection(by: 1)
        // The store records a copy of the same text as a new entry on top.
        state.update(entries(["middle"]) + [kept[0], kept[2]])
        XCTAssertEqual(state.selectedIndex, 0)
        XCTAssertEqual(state.selected?.text, "middle")
    }

    func testARemovedSelectionFallsToARowThatExists() {
        let state = ClipboardHistoryPanelState()
        let kept = entries(["newest", "middle", "older"])
        state.update(kept)
        state.moveSelection(by: 2)
        state.update(Array(kept.prefix(2)))
        XCTAssertEqual(state.selected?.text, "middle")
        state.update([])
        XCTAssertNil(state.selected)
        XCTAssertEqual(state.selectedIndex, 0)
    }

    func testSearchSelectsTheFirstMatchAndKeysWalkTheMatches() {
        let state = ClipboardHistoryPanelState()
        state.update(entries(["apple pie", "banana", "apple juice", "cherry"]))
        state.moveSelection(by: 3)
        state.query = "apple"
        XCTAssertEqual(state.selected?.text, "apple pie")
        state.moveSelection(by: 1)
        XCTAssertEqual(state.selected?.text, "apple juice")
        state.moveSelection(by: 1)
        XCTAssertEqual(state.selected?.text, "apple juice", "The selection stays within the matches")
    }

    func testAClickOrThePointerSelectsTheItemItIsOnEvenAfterTheListChanged() {
        let state = ClipboardHistoryPanelState()
        let kept = entries(["newest", "middle", "older"])
        state.update(kept)
        state.update(entries(["just copied"]) + kept)
        state.select(id: kept[1].id)
        XCTAssertEqual(state.selected?.text, "middle")
        XCTAssertFalse(state.selectionFromPointer)
        state.select(id: kept[2].id, byPointer: true)
        XCTAssertEqual(state.selected?.text, "older")
        XCTAssertTrue(state.selectionFromPointer, "A row the pointer chose is not scrolled away from it")
        state.select(id: UUID(), byPointer: true)
        XCTAssertEqual(state.selected?.text, "older", "An item no longer listed changes nothing")
        state.moveSelection(by: -1)
        XCTAssertFalse(state.selectionFromPointer)
    }

    func testTheRowUnderAScrolledPointerComesFromItsDistanceFromTheTop() {
        let height = ClipboardHistoryLayout.rowHeight
        XCTAssertEqual(ClipboardHistoryLayout.row(at: 0, count: 3), 0)
        XCTAssertEqual(ClipboardHistoryLayout.row(at: height - 0.5, count: 3), 0)
        XCTAssertEqual(ClipboardHistoryLayout.row(at: height * 2.5, count: 3), 2)
        XCTAssertNil(ClipboardHistoryLayout.row(at: height * 3, count: 3), "Below the last row")
        XCTAssertNil(ClipboardHistoryLayout.row(at: -1, count: 3))
        XCTAssertNil(ClipboardHistoryLayout.row(at: 10, count: 0))
    }
}
