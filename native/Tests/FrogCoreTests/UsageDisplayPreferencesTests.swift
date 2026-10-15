import XCTest
@testable import FrogCore

final class UsageDisplayPreferencesTests: XCTestCase {
    func testChoicesSavedBeforeClaudeAccountsLoadWithTheirDefaults() throws {
        let saved = Data(#"{"provider":"OpenAI","range":"30d","metric":"Input","allDevices":true,"loginSource":"Pi"}"#.utf8)
        let preferences = try JSONDecoder().decode(UsageDisplayPreferences.self, from: saved)
        XCTAssertEqual(preferences, UsageDisplayPreferences(provider: "OpenAI", range: "30d", metric: "Input", allDevices: true, loginSource: "Pi"))
        XCTAssertFalse(preferences.claudeAccounts)
        XCTAssertEqual(preferences.claudeAccountsView, "each")
        XCTAssertEqual(preferences.claudeAccountsMenuBar, "session")
        XCTAssertNoThrow(try preferences.validate())
        XCTAssertEqual(try JSONDecoder().decode(UsageDisplayPreferences.self, from: Data("{}".utf8)), UsageDisplayPreferences())
    }

    func testUnknownChoicesAreRejected() {
        XCTAssertThrowsError(try UsageDisplayPreferences(claudeAccountsView: "stacked").validate()) {
            XCTAssertEqual($0.localizedDescription, "Choose each or combined for Claude accounts.")
        }
        XCTAssertThrowsError(try UsageDisplayPreferences(claudeAccountsMenuBar: "month").validate()) {
            XCTAssertEqual($0.localizedDescription, "Choose session or week for the Claude accounts menu bar item.")
        }
    }

    func testAllEightFieldsRoundTrip() throws {
        let preferences = UsageDisplayPreferences(provider: "OpenAI", range: "24h", metric: "Output", allDevices: true, loginSource: "Claude Code",
                                                  claudeAccounts: true, claudeAccountsView: "combined", claudeAccountsMenuBar: "week")
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(UsageDisplayPreferences.self, from: data), preferences)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["provider", "range", "metric", "allDevices", "loginSource",
                                   "claudeAccounts", "claudeAccountsView", "claudeAccountsMenuBar"],
                       "Account labels and folders are never part of the portable choices")
    }
}
