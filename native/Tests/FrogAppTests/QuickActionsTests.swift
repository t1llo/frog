import FrogCore
import XCTest
@testable import FrogApp

final class QuickActionsTests: XCTestCase {
    func testSwitchAppearanceChangesWhatIsOnScreenAlsoWhenTheModeFollowsTheSystem() {
        XCTAssertEqual(AppearancePreferences.Mode.switched(from: nil, systemIsDark: true), .light, "A dark Mac with no mode chosen turns light")
        XCTAssertEqual(AppearancePreferences.Mode.switched(from: .system, systemIsDark: true), .light, "A dark Mac turns light")
        XCTAssertEqual(AppearancePreferences.Mode.switched(from: .system, systemIsDark: false), .dark)
        XCTAssertEqual(AppearancePreferences.Mode.switched(from: nil, systemIsDark: false), .dark)
        XCTAssertEqual(AppearancePreferences.Mode.switched(from: .dark, systemIsDark: true), .light)
        XCTAssertEqual(AppearancePreferences.Mode.switched(from: .dark, systemIsDark: false), .light, "A chosen mode wins over the system's")
        XCTAssertEqual(AppearancePreferences.Mode.switched(from: .light, systemIsDark: true), .dark)
        XCTAssertEqual(AppearancePreferences.Mode.switched(from: .light, systemIsDark: false), .dark)
    }

    func testBase64DecodeReadsTextThatWasPastedWithLineBreaks() {
        let text = String(repeating: "Frog keeps the text it decodes. ", count: 4)
        let encoded = Data(text.utf8).base64EncodedString(options: .lineLength76Characters)
        XCTAssertTrue(encoded.contains("\r\n"), "The fixture is wrapped the way mail and PEM wrap Base64")
        XCTAssertEqual(QuickTextTools.base64Decoded(encoded), text)
        XCTAssertEqual(QuickTextTools.base64Decoded("RnJvZw==\n"), "Frog", "A trailing line break")
        XCTAssertEqual(QuickTextTools.base64Decoded("  RnJv\nZw==  \n"), "Frog")
    }

    func testBase64DecodeStillRejectsWhatIsNotBase64OrNotText() {
        XCTAssertNil(QuickTextTools.base64Decoded("Rn*JvZw=="), "A stray character is reported, not skipped")
        XCTAssertNil(QuickTextTools.base64Decoded("RnJvZw"), "Missing padding")
        XCTAssertNil(QuickTextTools.base64Decoded(Data([0xFF, 0xFE, 0x00]).base64EncodedString()), "Bytes that are not UTF-8")
        XCTAssertEqual(QuickTextTools.base64Decoded(" \n"), "", "Blank input is empty, as an empty field always was")
    }
}
