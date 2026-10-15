import XCTest
@testable import FrogCore

final class TextConfigurationTests: XCTestCase {
    func testTheClaudeAccountsChoicesRoundTripThroughTheTextFile() throws {
        let companion = try TextConfiguration.companion(Configuration())
        let text = "usage.claude-accounts = true\nusage.claude-accounts-view = combined\nusage.claude-accounts-menu-bar = week\n"
        let loaded = try TextConfiguration.decode(text, companion: companion)
        let usage = try XCTUnwrap(loaded.preferences.toolkit?.usage)
        XCTAssertTrue(usage.claudeAccounts)
        XCTAssertEqual(usage.claudeAccountsView, "combined")
        XCTAssertEqual(usage.claudeAccountsMenuBar, "week")
        let rendered = try TextConfiguration.render(loaded)
        for line in text.split(separator: "\n") { XCTAssertTrue(rendered.contains(line), "\(line) is written back") }
        XCTAssertEqual(try TextConfiguration.decode(rendered, companion: TextConfiguration.companion(loaded)).preferences.toolkit?.usage, usage)

        // Unset, they read as the defaults: off, each account, the session.
        let defaults = try XCTUnwrap(TextConfiguration.decode("usage.range = 7d\n", companion: companion).preferences.toolkit?.usage)
        XCTAssertFalse(defaults.claudeAccounts)
        XCTAssertEqual(defaults.claudeAccountsView, "each")
        XCTAssertEqual(defaults.claudeAccountsMenuBar, "session")
    }

    func testAnUnknownClaudeAccountsViewIsRefusedWithItsLine() throws {
        let companion = try TextConfiguration.companion(Configuration())
        XCTAssertThrowsError(try TextConfiguration.decode("usage.claude-accounts-view = both\n", companion: companion)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("config:1: usage.claude-accounts-view: choose each, combined"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try TextConfiguration.decode("usage.claude-accounts-menu-bar = month\n", companion: companion)) {
            XCTAssertTrue($0.localizedDescription.contains("choose session, week"), $0.localizedDescription)
        }
        // The same choice written into config.json is refused by the usage validation.
        var configuration = Configuration()
        configuration.preferences.toolkit = configuration.preferences.toolkit ?? ToolkitPreferences()
        configuration.preferences.toolkit?.usage = UsageDisplayPreferences(claudeAccountsView: "both")
        XCTAssertThrowsError(try ConfigurationFile.decode(JSONEncoder().encode(configuration))) {
            XCTAssertTrue($0.localizedDescription.contains("Choose each or combined for Claude accounts."), $0.localizedDescription)
        }
    }
}
