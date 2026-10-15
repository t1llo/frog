import XCTest
@testable import FrogCore

final class ExplainSettingsTests: XCTestCase {
    func testAnEmptyObjectDecodesToTheDefaults() throws {
        let settings = try JSONDecoder().decode(ExplainSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, ExplainSettings())
        XCTAssertTrue(settings.includeContext)
        XCTAssertTrue(Preferences().explainSettings.includeContext)
        XCTAssertFalse(Preferences().featureEnabled(.explain))
    }

    func testIncludeContextRoundTripsThroughTheTextFile() throws {
        let companion = try TextConfiguration.companion(Configuration())
        let loaded = try TextConfiguration.decode("explain.context = false\n", companion: companion)
        XCTAssertEqual(loaded.preferences.toolkit?.explain?.includeContext, false)
        XCTAssertFalse(loaded.preferences.explainSettings.includeContext)
        let text = try TextConfiguration.render(loaded)
        XCTAssertTrue(text.contains("\nexplain.context = false\n"), text)
        XCTAssertEqual(try TextConfiguration.decode(text, companion: TextConfiguration.companion(loaded)), loaded)
        try ConfigurationFile.validate(loaded)
    }

    func testMissingSettingsRenderNothingAndAreFilledWhenEdited() throws {
        let plain = try TextConfiguration.render(Configuration())
        XCTAssertFalse(plain.contains("explain."), plain)

        // A file that sets another toolkit value reads Explain's defaults.
        var configuration = Configuration()
        configuration.preferences.setFeature(.explain, enabled: true)
        let edited = try TextConfiguration.decode(TextConfiguration.render(configuration), companion: TextConfiguration.companion(configuration))
        XCTAssertTrue(edited.preferences.featureEnabled(.explain))
        XCTAssertTrue(edited.preferences.explainSettings.includeContext)

        // Settings that hold their default stay out of an existing file that does not name them.
        var withSettings = configuration
        withSettings.preferences.toolkit?.explain = ExplainSettings()
        let existing = try TextConfiguration.render(configuration)
        XCTAssertFalse(try TextConfiguration.render(withSettings, preserving: existing).contains("explain.context"))
        XCTAssertTrue(try TextConfiguration.render(withSettings).contains("\nexplain.context = true\n"))
    }
}
