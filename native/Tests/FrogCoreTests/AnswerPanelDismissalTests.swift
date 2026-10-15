import XCTest
@testable import FrogCore

final class AnswerPanelDismissalTests: XCTestCase {
    func testEveryEventInBothPinStates() {
        let table: [(PanelEvent, unpinned: Bool, pinned: Bool)] = [
            (.closeButton, true, true),
            (.escapeInPanel, true, true),
            (.escapeElsewhere, true, false),
            (.clickOutside, true, false),
            (.appActivated(isSource: false), true, false),
            (.appActivated(isSource: true), false, false),
        ]
        for (event, unpinned, pinned) in table {
            XCTAssertEqual(AnswerPanelDismissal.shouldClose(event, pinned: false), unpinned, "\(event) unpinned")
            XCTAssertEqual(AnswerPanelDismissal.shouldClose(event, pinned: true), pinned, "\(event) pinned")
        }
    }
}
