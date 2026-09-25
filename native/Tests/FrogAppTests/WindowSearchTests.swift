import XCTest
@testable import FrogApp

final class WindowSearchTests: XCTestCase {
    func testFuzzySearchMatchesAcrossAppAndTitleAndFoldsAccents() {
        XCTAssertNotNil(WindowSearch.score("sfrprj", in: "Safari Project"))
        XCTAssertNotNil(WindowSearch.score("resume", in: "Résumé"))
        XCTAssertNil(WindowSearch.score("zz", in: "Safari Project"))
        XCTAssertGreaterThan(WindowSearch.score("proj", in: "Project")!, WindowSearch.score("proj", in: "Personal remote object journal")!)
    }
    func testSearchKeysDoNotLeakAsCommandShortcuts() {
        var router = WindowSwitchKeyRouter()
        _ = router.key(code: 48, down: true, command: true, shift: false, otherModifiers: false)
        let search = router.key(code: 0, down: true, command: true, shift: false, otherModifiers: false, text: "a")
        XCTAssertTrue(search.consume)
        XCTAssertEqual(search.action, .search("a"))
        XCTAssertTrue(router.key(code: 0, down: false, command: true, shift: false, otherModifiers: false).consume)
        XCTAssertEqual(router.key(code: 51, down: true, command: true, shift: false, otherModifiers: false).action, .deleteSearch)
        XCTAssertEqual(router.modifiers(command: false).action, .commit)
    }
}
