import XCTest
import FrogCore
@testable import FrogApp

/// Hovering the layout picker's tiles, without showing the panel.
@MainActor final class LayoutPickerHoverTests: XCTestCase {
    func testAHoverUnderAPointerThatHasNotMovedSinceAKeyKeepsTheSelection() {
        let panel = LayoutPickerPanel()
        var pointer = CGPoint(x: 500, y: 400)
        panel.mouseLocation = { pointer }
        var selected: [WindowAction?] = []
        panel.onSelect = { selected.append($0) }
        let first = panel.picker.selection
        XCTAssertNotNil(first)

        // An arrow key moved the selection; the tile now under the resting pointer reports a hover.
        panel.pointerRests()
        panel.hovered(.rightHalf)
        XCTAssertEqual(panel.picker.selection, first)
        XCTAssertEqual(selected, [])

        // The mouse moves: hovering selects.
        pointer.x += 3
        panel.hovered(.rightHalf)
        XCTAssertEqual(panel.picker.selection, .rightHalf)
        panel.hovered(.center)
        XCTAssertEqual(panel.picker.selection, .center, "Once the mouse has moved, hovers select until the next key")
        XCTAssertEqual(selected, [.rightHalf, .center])
    }
}
