import XCTest
@testable import FrogCore

final class PaletteRoleTests: XCTestCase {
    /// Frog draws nothing with `on-accent`, so a new file does not offer it. A file that sets it still loads.
    func testNewFilesDoNotOfferTheUnusedOnAccentRoleAndOlderFilesStillLoad() throws {
        let text = try TextConfiguration.render(Configuration())
        XCTAssertTrue(text.contains("# Palette names:"))
        XCTAssertFalse(text.contains("on-accent"), "A new file must not offer a color that changes nothing")

        let older = text + "palette.dark.on-accent = #001122\n"
        let loaded = try TextConfiguration.decode(older, companion: TextConfiguration.companion(Configuration()))
        XCTAssertEqual(loaded.preferences.appearance?.darkPalette?["on-accent"], "001122")
    }
}
