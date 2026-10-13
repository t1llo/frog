import ApplicationServices
import XCTest
@testable import FrogApp

@MainActor
final class MenuCommandTests: XCTestCase {
    // Plain identities; nothing is asked of these processes.
    private let copy = AXUIElementCreateApplication(900_101)
    private let paste = AXUIElementCreateApplication(900_102)

    func testOneSelectionWalksTheMenuBarOncePerCommand() {
        var walks: [String] = []
        let menu = MenuCommandCache(find: { walks.append($0); return $0 == "c" ? self.copy : self.paste },
                                    matches: { _, _ in true })
        // One rule run asks for Copy twice and for Paste up to three times.
        for character in ["c", "v", "c", "v", "v"] {
            XCTAssertTrue(menu.item(character).map { CFEqual($0, character == "c" ? copy : paste) } ?? false)
        }
        XCTAssertEqual(walks, ["c", "v"])
    }

    func testRememberedItemIsCheckedAgainstItsOwnCommand() {
        var checked: [String] = []
        let menu = MenuCommandCache(find: { $0 == "c" ? self.copy : self.paste },
                                    matches: { item, character in
                                        checked.append(character + (CFEqual(item, self.copy) ? ":copy" : ":paste"))
                                        return true
                                    })
        _ = menu.item("c"); _ = menu.item("v")
        XCTAssertEqual(checked, [], "A freshly found item needs no second check")
        _ = menu.item("v"); _ = menu.item("c")
        XCTAssertEqual(checked, ["v:paste", "c:copy"])
    }

    func testDisabledOrReplacedItemIsLookedUpAgain() {
        var walks = 0
        var matches = true
        let menu = MenuCommandCache(find: { _ in walks += 1; return walks == 1 ? self.paste : self.copy },
                                    matches: { _, _ in matches })
        XCTAssertTrue(menu.item("v").map { CFEqual($0, paste) } ?? false)
        // The app disabled the item, or rebuilt its menu so that it is another command now.
        matches = false
        XCTAssertTrue(menu.item("v").map { CFEqual($0, copy) } ?? false,
                      "A remembered item that no longer is the command must not stand in for a fresh search")
        XCTAssertEqual(walks, 2)
    }

    func testMissingCommandIsSearchedAgainNextTime() {
        var walks = 0
        let menu = MenuCommandCache(find: { _ in walks += 1; return walks == 1 ? nil : self.paste },
                                    matches: { _, _ in true })
        XCTAssertNil(menu.item("v"))
        XCTAssertTrue(menu.item("v").map { CFEqual($0, paste) } ?? false)
        XCTAssertTrue(menu.item("v").map { CFEqual($0, paste) } ?? false)
        XCTAssertEqual(walks, 2)
    }
}
