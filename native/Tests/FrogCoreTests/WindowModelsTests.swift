import XCTest
@testable import FrogCore

final class WindowModelsTests: XCTestCase {
    private func display(_ name: String, _ visible: CGRect) -> WindowDisplay {
        WindowDisplay(id: name, name: name, frame: visible, visibleFrame: visible)
    }

    func testSideBySideDisplaysOrderLeftToRight() {
        let right = display("Right", CGRect(x: 1440, y: 0, width: 1920, height: 1080))
        let left = display("Left", CGRect(x: 0, y: 25, width: 1440, height: 875))
        XCTAssertEqual(WindowDisplay.ordered([right, left]).map(\.name), ["Left", "Right"])
    }

    func testStackedDisplaysOrderTopToBottom() {
        let lower = display("Lower", CGRect(x: 0, y: 25, width: 1440, height: 875))
        let upper = display("Upper", CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        XCTAssertEqual(WindowDisplay.ordered([lower, upper]).map(\.name), ["Upper", "Lower"])
    }

    func testThreeDisplaysOrderLeftToRightThenTopToBottom() {
        let laptop = display("Laptop", CGRect(x: 0, y: 25, width: 1512, height: 957))
        let external = display("External", CGRect(x: -2560, y: 0, width: 2560, height: 1415))
        let above = display("Above", CGRect(x: 0, y: -1080, width: 1920, height: 1055))
        XCTAssertEqual(WindowDisplay.ordered([laptop, external, above]).map(\.name), ["External", "Above", "Laptop"])
        XCTAssertEqual(WindowDisplay.ordered([above, laptop, external]).map(\.name), ["External", "Above", "Laptop"])
    }

    func testSignatureNamesTheDisplayAndItsFullSize() {
        let studio = WindowDisplay(id: "UUID", name: "Studio Display", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                   visibleFrame: CGRect(x: 0, y: 25, width: 2560, height: 1415))
        XCTAssertEqual(studio.signature, "Studio Display 2560×1440")
    }

    func testWindowKeyHashesAndRoundTrips() throws {
        let key = WindowKey(pid: 42, number: 7)
        XCTAssertEqual(Set([key, WindowKey(pid: 42, number: 7), WindowKey(pid: 42, number: 8)]).count, 2)
        XCTAssertNotEqual(key, WindowKey(pid: 43, number: 7))
        XCTAssertEqual(try JSONDecoder().decode(WindowKey.self, from: JSONEncoder().encode(key)), key)
    }
}
