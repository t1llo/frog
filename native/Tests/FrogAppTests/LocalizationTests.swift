import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class LocalizationTests: XCTestCase {
    func testLegacyLanguageSettingStillLoadsAndDisplaysEnglish() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil }, writeClipboard: { _ in })
        defer { model.shutdown() }
        try model.savePreferences(model.configuration.preferences)
        let file = model.configurationFileURL
        let text = try String(contentsOf: file)
        XCTAssertFalse(text.contains("language = "))
        try Data((text + "language = de\n").utf8).write(to: file)

        try model.reloadConfiguration()
        XCTAssertEqual(model.configuration.preferences.workflowSettings.applicationLanguage, "de")
        // A configuration that no longer loads would block every later save.
        var preferences = model.configuration.preferences
        preferences.historyLimit = 20
        try model.savePreferences(preferences)
        XCTAssertTrue(try String(contentsOf: file).contains("language = de"))

        XCTAssertEqual(L10n.locale.identifier, "en")
        XCTAssertEqual(L10n.text("Settings"), "Settings")
        XCTAssertEqual(L10n.text("Inside Frog"), "Inside Frog")
        XCTAssertEqual(L10n.text("My custom rule"), "My custom rule")
        XCTAssertEqual(L10n.text("Rules"), "Rules")
    }
}
