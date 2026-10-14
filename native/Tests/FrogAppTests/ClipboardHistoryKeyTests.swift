import AppKit
import XCTest
@testable import FrogApp

/// The keys the clipboard panel leaves to the search field, decided on a text view of the test. No panel is shown.
@MainActor
final class ClipboardHistoryKeyTests: XCTestCase {
    func testAnInputMethodThatIsComposingInTheSearchKeepsTheKeysThatActOnTheList() {
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        XCTAssertFalse(ClipboardHistoryController.isComposing(field))
        field.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(field.hasMarkedText())
        XCTAssertTrue(ClipboardHistoryController.isComposing(field), "Return, the arrows and Escape pick or cancel a candidate")
        field.unmarkText()
        XCTAssertFalse(ClipboardHistoryController.isComposing(field))
        XCTAssertFalse(ClipboardHistoryController.isComposing(nil))
        XCTAssertFalse(ClipboardHistoryController.isComposing(NSView()))
    }
}
