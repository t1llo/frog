import XCTest
@testable import FrogApp

@MainActor
final class LocalizationTests: XCTestCase {
    func testExplicitLanguageOverridesSystemAndMissingTextFallsBack() async {
        let previous = AppLanguage.shared.selection
        defer { AppLanguage.shared.selection = previous }
        AppLanguage.shared.selection = "de"
        XCTAssertEqual(L10n.text("Settings"), "Einstellungen")
        XCTAssertEqual(L10n.text("Inside Frog"), "In Frog")
        XCTAssertEqual(L10n.text("My custom rule"), "My custom rule")
        AppLanguage.shared.selection = "en"
        XCTAssertEqual(L10n.text("Settings"), "Settings")
    }
}
