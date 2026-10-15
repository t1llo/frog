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

    func testLearnChoicesRoundTripsThroughTheTextConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        var configuration = Configuration(); configuration.preferences.setFeature(.commandBar, enabled: true)
        try store.save(configuration)
        // Without the setting no commandBar group is written, so an older Frog reads the file as before.
        XCTAssertFalse(try String(contentsOf: store.textFile, encoding: .utf8).contains("command-bar."))
        var loaded = try store.load()
        XCTAssertNil(loaded.preferences.toolkit?.commandBar)
        XCTAssertFalse(loaded.preferences.toolkitSettings.commandBarSettings.learnChoices)

        loaded.preferences.toolkit?.commandBar = CommandBarPreferences()
        loaded.preferences.toolkit?.commandBar?.learnChoices = true
        try store.save(loaded)
        let text = try String(contentsOf: store.textFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\ncommand-bar.learn-choices = true\n"))
        XCTAssertEqual(try ConfigurationStore(directory: directory).load(), loaded)

        try Data(text.replacingOccurrences(of: "command-bar.learn-choices = true", with: "command-bar.learn-choices = false").utf8).write(to: store.textFile)
        XCTAssertFalse(try store.load().preferences.toolkitSettings.commandBarSettings.learnChoices)
    }
}
