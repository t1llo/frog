import XCTest
@testable import FrogApp

@MainActor
final class LocalizationTests: XCTestCase {
    func testLegacyLanguageSettingStillDisplaysEnglish() async {
        let previous = AppLanguage.shared.selection
        defer { AppLanguage.shared.selection = previous }
        AppLanguage.shared.selection = "de"
        XCTAssertEqual(L10n.text("Settings"), "Settings")
        XCTAssertEqual(L10n.text("Inside Frog"), "Inside Frog")
        XCTAssertEqual(L10n.text("My custom rule"), "My custom rule")
        AppLanguage.shared.selection = "en"
        XCTAssertEqual(L10n.text("Settings"), "Settings")
    }
}
