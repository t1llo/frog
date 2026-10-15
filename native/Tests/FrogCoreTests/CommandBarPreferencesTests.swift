import XCTest
@testable import FrogCore

final class CommandBarPreferencesTests: XCTestCase {
    func testLearningIsOffUntilChosenAndUnknownKeysAreIgnored() throws {
        let empty = try JSONDecoder().decode(CommandBarPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, CommandBarPreferences())
        XCTAssertFalse(empty.learnChoices)
        let later = try JSONDecoder().decode(CommandBarPreferences.self, from: Data(#"{"learnChoices":true,"fromALaterVersion":3}"#.utf8))
        XCTAssertTrue(later.learnChoices)
        XCTAssertNoThrow(try later.validate())
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(later)) as? [String: Any])
        XCTAssertEqual(encoded["learnChoices"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(CommandBarPreferences.self, from: JSONEncoder().encode(later)), later)
    }

    func testAToolkitWithoutCommandBarSettingsStaysWithout() throws {
        let toolkit = try JSONDecoder().decode(ToolkitPreferences.self, from: Data(#"{"enabled":{"commandBar":true}}"#.utf8))
        XCTAssertNil(toolkit.commandBar)
        XCTAssertFalse(toolkit.commandBarSettings.learnChoices)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(toolkit)) as? [String: Any])
        XCTAssertNil(encoded["commandBar"])

        var learning = ToolkitPreferences(); learning.commandBar = CommandBarPreferences(); learning.commandBar?.learnChoices = true
        let reloaded = try JSONDecoder().decode(ToolkitPreferences.self, from: JSONEncoder().encode(learning))
        XCTAssertTrue(reloaded.commandBarSettings.learnChoices)
    }
}
