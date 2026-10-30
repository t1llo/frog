import FrogTestSupport
import XCTest
@testable import FrogUsage

/// Choosing a look on the LLM usage page goes through `updatePreferences`; the choice must survive
/// its checks and reach the owner, which keeps it in config.toml. Nothing is kept in UserDefaults.
@MainActor final class UsageMenuBarDesignTests: XCTestCase {
    func testAChosenDesignIsKeptAndHandedToTheOwner() {
        let defaults = temporaryDefaults()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: root)
        var written: [UsageDashboardPreferences] = []
        usage.onPreferencesChange = { written.append($0) }

        var next = usage.preferences
        next.menuBarStyle = "segments"; next.menuBarPalette = "spectrum"
        usage.updatePreferences(next)
        XCTAssertEqual(usage.preferences.menuBarStyle, "segments")
        XCTAssertEqual(usage.preferences.menuBarPalette, "spectrum")
        XCTAssertEqual(written.last?.menuBarStyle, "segments", "The configuration file gets the choice")

        let again = UsageDashboardModel(defaults: defaults, fixtureRoot: root)
        XCTAssertEqual(again.preferences.menuBarStyle, UsageDashboardPreferences().menuBarStyle,
                       "A new model starts from the defaults; the owner applies config.toml")

        // An imported configuration applies its design too; an unknown one falls back.
        var imported = again.preferences
        imported.menuBarStyle = "columns"; imported.menuBarPalette = "neon"
        again.applyPreferences(imported)
        XCTAssertEqual(again.preferences.menuBarStyle, "columns")
        XCTAssertEqual(again.preferences.menuBarPalette, "clean")
    }
}
