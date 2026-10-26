import XCTest
@testable import FrogCore

final class CleanerPreferencesTests: XCTestCase {
    func testEmptySettingsDecodeWithEverySwitchOff() throws {
        let value = try JSONDecoder().decode(CleanerPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(value, CleanerPreferences())
        XCTAssertFalse(value.possibleMatches)
        XCTAssertEqual(Preferences().cleanerSettings, CleanerPreferences())
    }

    func testTheCleanerIsOffByDefaultAndItsSwitchesNeedIt() {
        var preferences = Preferences()
        XCTAssertFalse(preferences.featureEnabled(.cleaner))
        XCTAssertFalse(preferences.sidebarFeatures.contains(.cleaner))
        preferences.ensureToolkit()
        var settings = CleanerPreferences()
        settings.possibleMatches = true
        preferences.toolkit?.cleaner = settings
        // The switch is saved but means nothing until the feature is on.
        XCTAssertTrue(preferences.cleanerSettings.possibleMatches)
        XCTAssertFalse(preferences.featureEnabled(.cleaner) && preferences.cleanerSettings.possibleMatches)
        preferences.setFeature(.cleaner, enabled: true)
        XCTAssertTrue(preferences.featureEnabled(.cleaner) && preferences.cleanerSettings.possibleMatches)
        XCTAssertTrue(preferences.sidebarFeatures.contains(.cleaner))
    }

    func testPossibleMatchesRoundTripsThroughTheTextFile() throws {
        var configuration = Configuration()
        configuration.preferences.ensureToolkit()
        configuration.preferences.toolkit?.cleaner = CleanerPreferences()
        let text = try TextConfiguration.render(configuration)
        XCTAssertTrue(text.contains("\ncleaner.possible-matches = false\n"), text)
        XCTAssertTrue(text.contains("\nfeature.cleaner = false\n") || !text.contains("feature.cleaner = true"), text)

        let companion = try TextConfiguration.companion(configuration)
        let loaded = try TextConfiguration.decode("cleaner.possible-matches = true\nfeature.cleaner = true\n", companion: companion)
        XCTAssertTrue(loaded.preferences.cleanerSettings.possibleMatches)
        XCTAssertTrue(loaded.preferences.featureEnabled(.cleaner))
        // Without the line the switch reads as its default.
        XCTAssertFalse(try TextConfiguration.decode("", companion: companion).preferences.cleanerSettings.possibleMatches)
        XCTAssertThrowsError(try TextConfiguration.decode("cleaner.possible-matches = maybe\n", companion: companion))
    }

    func testFeatureCleanerKeyIsGenerated() {
        XCTAssertTrue(TextConfiguration.keys.contains("feature.cleaner"))
        XCTAssertTrue(TextConfiguration.keys.contains("cleaner.possible-matches"))
        XCTAssertEqual(FeatureID.cleaner.title, "App cleaner")
    }
}
