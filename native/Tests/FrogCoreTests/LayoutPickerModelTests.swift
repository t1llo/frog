import XCTest
@testable import FrogCore

final class LayoutPickerModelTests: XCTestCase {
    func testSectionsComeInTheCheatSheetOrderWithFourTilesToARow() {
        let model = LayoutPickerModel(hotkeys: [:])
        XCTAssertEqual(model.sections.map(\.title), ["Halves", "Quarters", "Thirds", "Sizes", "More"])
        XCTAssertEqual(model.sections[0].tiles.map(\.action), [.leftHalf, .rightHalf, .topHalf, .bottomHalf])
        XCTAssertEqual(model.sections[2].rows.map { $0.map(\.action) }, [[.leftThird, .centerThird, .rightThird], [.leftTwoThirds, .rightTwoThirds]])
        XCTAssertEqual(model.sections[3].tiles.map(\.action), [.maximize, .centeredSmall, .centeredMedium, .centeredLarge])
        XCTAssertEqual(model.sections[4].tiles.map(\.action), [.center, .restore, .nextDisplay, .previousDisplay])
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
        // What a tile shows finds it too.
        model.setQuery("top left")
        XCTAssertEqual(model.visibleActions, [.topLeft])
        model.setQuery("70%")
        XCTAssertEqual(model.visibleActions, [.centeredMedium])
        // The cheat sheet's groups that More folds in still find their tiles.
        model.setQuery("undo")
        XCTAssertEqual(model.visibleActions, [.restore])
        model.setQuery("displays")
        XCTAssertEqual(model.visibleActions, [.nextDisplay, .previousDisplay])
        // The names layouts had before still find them.
        model.setQuery("quarter")
        XCTAssertEqual(Set(model.visibleActions), [.topLeft, .topRight, .bottomLeft, .bottomRight])
        model.setQuery("previous size")
        XCTAssertEqual(model.visibleActions, [.restore])
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
        model.move(.down)
        XCTAssertEqual(model.selection, .leftTwoThirds, "The two-thirds are a row of their own")
        model.move(.right)
        XCTAssertEqual(model.selection, .rightTwoThirds)
        model.move(.down)
        XCTAssertEqual(model.selection, .centeredSmall, "Down keeps the column")
        for _ in 0..<2 { model.move(.right) }
        model.move(.down)
        XCTAssertEqual(model.selection, .previousDisplay)
        model.move(.up)
        XCTAssertEqual(model.selection, .centeredLarge)
        for _ in 0..<10 { model.move(.down) }
        XCTAssertEqual(model.selection, .previousDisplay)
        model.move(.right)
        XCTAssertEqual(model.selection, .previousDisplay, "Clamped at the last tile")
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

    func testTilesHaveTheOneNameEverySurfaceUses() {
        let model = LayoutPickerModel(hotkeys: [:])
        XCTAssertEqual(model.sections[0].tiles.map(\.name), ["Left half", "Right half", "Top half", "Bottom half"])
        XCTAssertEqual(model.sections[1].tiles.map(\.name), ["Top left", "Top right", "Bottom left", "Bottom right"])
        XCTAssertEqual(model.sections[3].tiles.map(\.name), ["Maximize", "Centered 50%", "Centered 70%", "Centered 90%"])
        XCTAssertEqual(model.sections[4].tiles.map(\.name), ["Center", "Restore", "Next display", "Previous display"])
        XCTAssertEqual(model.sections[2].tiles.map(\.name), ["Left third", "Center third", "Right third", "Left two-thirds", "Right two-thirds"])
        for tile in model.sections.flatMap(\.tiles) { XCTAssertEqual(tile.name, tile.action.title) }
        let names = model.sections.flatMap { $0.tiles.map(\.name) }
        XCTAssertEqual(Set(names).count, names.count, "No two tiles share a name")
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
