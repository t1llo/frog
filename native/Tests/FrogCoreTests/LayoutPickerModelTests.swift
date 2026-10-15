import XCTest
@testable import FrogCore

final class LayoutPickerModelTests: XCTestCase {
    func testSectionsComeInTheCheatSheetOrderWithFourTilesToARow() {
        let model = LayoutPickerModel(hotkeys: [:])
        XCTAssertEqual(model.sections.map(\.title), ["Halves", "Quarters", "Thirds", "Sizes", "Displays", "Undo"])
        XCTAssertEqual(model.sections[0].tiles.map(\.action), [.leftHalf, .rightHalf, .topHalf, .bottomHalf])
        XCTAssertEqual(model.sections[2].rows.map { $0.map(\.action) }, [[.leftThird, .centerThird, .rightThird, .leftTwoThirds], [.rightTwoThirds]])
        XCTAssertEqual(model.sections[3].tiles.map(\.action), [.maximize, .center, .centeredSmall, .centeredMedium, .centeredLarge])
        XCTAssertEqual(model.sections[5].tiles.map(\.action), [.restore])
        XCTAssertEqual(model.selection, .leftHalf)
    }

    func testMinimizeAndFullScreenAreNotOffered() {
        let actions = LayoutPickerModel(hotkeys: [:]).visibleActions
        XCTAssertFalse(actions.contains(.minimize))
        XCTAssertFalse(actions.contains(.toggleFullScreen))
        XCTAssertEqual(actions.count, WindowAction.allCases.count - 2)
    }

    func testFilteringByTitle() {
        var model = LayoutPickerModel(hotkeys: [:])
        model.setQuery("third")
        XCTAssertEqual(model.visibleActions, [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds])
        model.setQuery("TWO")
        XCTAssertEqual(model.visibleActions, [.leftTwoThirds, .rightTwoThirds])
        model.setQuery("nothing like it")
        XCTAssertEqual(model.sections, [])
        XCTAssertNil(model.selection)
        model.move(.right)
        XCTAssertNil(model.selection)
    }

    func testArrowsMoveAcrossRowsAndStopAtTheEnds() {
        var model = LayoutPickerModel(hotkeys: [:])
        model.move(.left)
        XCTAssertEqual(model.selection, .leftHalf, "Clamped at the first tile")
        model.move(.up)
        XCTAssertEqual(model.selection, .leftHalf)
        for _ in 0..<3 { model.move(.right) }
        XCTAssertEqual(model.selection, .bottomHalf)
        model.move(.right)
        XCTAssertEqual(model.selection, .topLeft, "Right at the end of a row goes on to the next row")
        model.move(.down)
        XCTAssertEqual(model.selection, .leftThird)
        model.move(.right); model.move(.right); model.move(.right)
        XCTAssertEqual(model.selection, .leftTwoThirds)
        model.move(.down)
        XCTAssertEqual(model.selection, .rightTwoThirds, "A shorter row keeps its last tile")
        model.move(.up)
        XCTAssertEqual(model.selection, .leftThird)
        for _ in 0..<10 { model.move(.down) }
        XCTAssertEqual(model.selection, .restore)
        model.move(.right)
        XCTAssertEqual(model.selection, .restore, "Clamped at the last tile")
    }

    func testFilteringKeepsAVisibleSelectionElseSelectsTheFirst() {
        var model = LayoutPickerModel(hotkeys: [:])
        model.select(.centerThird)
        model.setQuery("third")
        XCTAssertEqual(model.selection, .centerThird)
        model.setQuery("two")
        XCTAssertEqual(model.selection, .leftTwoThirds)
        model.setQuery("")
        XCTAssertEqual(model.selection, .leftTwoThirds)
        model.select(.minimize)
        XCTAssertEqual(model.selection, .leftTwoThirds, "A layout the picker does not offer cannot be selected")
    }

    func testShortcutsArePassedToTheirTiles() {
        let key = Hotkey(keyCode: 124, modifiers: 4096 | 2048)
        let model = LayoutPickerModel(hotkeys: [.rightHalf: key])
        let tiles = model.sections.flatMap(\.tiles)
        XCTAssertEqual(tiles.first { $0.action == .rightHalf }?.hotkey, key)
        XCTAssertEqual(tiles.first { $0.action == .rightHalf }?.title, WindowAction.rightHalf.title)
        XCTAssertNil(tiles.first { $0.action == .leftHalf }?.hotkey)
    }
}
