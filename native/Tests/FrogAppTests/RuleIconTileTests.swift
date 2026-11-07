import XCTest
@testable import FrogApp

final class RuleIconTileTests: XCTestCase {
    func testTranslationShowsTheLanguageItTranslatesInto() {
        let symbol = "translate"
        XCTAssertEqual(RuleIconTile.languageCode(name: "Translate to German", symbol: symbol), "DE")
        XCTAssertEqual(RuleIconTile.languageCode(name: "Translate English to German", symbol: symbol), "DE")
        XCTAssertEqual(RuleIconTile.languageCode(name: "Translate into French", symbol: symbol), "FR")
        XCTAssertEqual(RuleIconTile.languageCode(name: "Übersetzen nach Englisch", symbol: symbol), "EN")
        XCTAssertEqual(RuleIconTile.languageCode(name: "Translate German English", symbol: symbol), "EN")
        XCTAssertNil(RuleIconTile.languageCode(name: "Proofread", symbol: "checkmark.circle"))
        XCTAssertNil(RuleIconTile.languageCode(name: "Translate", symbol: symbol))
    }
}
