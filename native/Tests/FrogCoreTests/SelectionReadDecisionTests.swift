import XCTest
@testable import FrogCore

final class SelectionReadDecisionTests: XCTestCase {
    private func step(_ role: String?, subrole: String? = nil, _ range: (Int, Int)?, max: Int = 100_000) -> SelectionReadDecision.Step {
        SelectionReadDecision.attributes(role: role, subrole: subrole, range: range.map { (location: $0.0, length: $0.1) },
                                         maxCharacters: max)
    }

    func testAPasswordFieldIsSecureBeforeAnythingElse() {
        XCTAssertEqual(step("AXTextField", subrole: "AXSecureTextField", (0, 4)), .secure)
        XCTAssertEqual(step("AXTextField", subrole: "AXSecureTextField", nil), .secure)
        XCTAssertEqual(step("AXTextField", subrole: "AXSecureTextField", (0, 0)), .secure)
    }

    func testWithoutARangeTextMarkersAreTried() {
        XCTAssertEqual(step("AXWebArea", nil), .tryMarkers)
        XCTAssertEqual(step("AXTextArea", nil), .tryMarkers)
        XCTAssertEqual(step(nil, nil), .tryMarkers)
    }

    func testACaretIsEmptyOnlyInTextFields() {
        XCTAssertEqual(step("AXTextArea", (12, 0)), .empty)
        XCTAssertEqual(step("AXTextField", (0, 0)), .empty)
        for role in ["AXWebArea", "AXGroup", "AXStaticText", nil] {
            XCTAssertEqual(step(role, (12, 0)), .tryMarkers, role ?? "nil")
        }
    }

    func testLengthIsCheckedBeforeTheTextIsRead() {
        XCTAssertEqual(step("AXTextArea", (0, 100_001)), .tooLong(100_001))
        XCTAssertEqual(step("AXTextArea", (0, 100_000)), .readAttributes)
        XCTAssertEqual(step("AXStaticText", (5, 3)), .readAttributes)
    }

    func testMarkerText() {
        XCTAssertEqual(SelectionReadDecision.markers(textLength: nil, maxCharacters: 100), .unavailable)
        XCTAssertEqual(SelectionReadDecision.markers(textLength: 0, maxCharacters: 100), .unavailable)
        XCTAssertEqual(SelectionReadDecision.markers(textLength: 101, maxCharacters: 100), .tooLong(101))
        XCTAssertNil(SelectionReadDecision.markers(textLength: 100, maxCharacters: 100))
        XCTAssertNil(SelectionReadDecision.markers(textLength: 1, maxCharacters: 100))
    }
}
