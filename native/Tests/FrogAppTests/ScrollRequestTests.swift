import XCTest
@testable import FrogApp

final class ScrollRequestTests: XCTestCase {
    func testFinishSetupScrollsSettingsToPermissionsOnlyOnTheVisitItOpened() {
        var request = ScrollRequest()
        XCTAssertFalse(request.take(), "Settings opens at its top when nothing asked for a section")

        request.ask()
        XCTAssertNotNil(request.id)
        XCTAssertTrue(request.take())
        XCTAssertNil(request.id, "The visit that scrolled has to use the request up")
        XCTAssertFalse(request.take(), "A later visit to Settings has to open at the top again")

        request.ask()
        XCTAssertTrue(request.take(), "Finish setup has to scroll again when it is clicked again")
    }

    func testEveryRequestIsANewOneSoAskingAgainScrollsAgain() {
        var request = ScrollRequest()
        request.ask()
        let first = request.id
        request.ask()
        XCTAssertNotEqual(request.id, first)
    }
}
