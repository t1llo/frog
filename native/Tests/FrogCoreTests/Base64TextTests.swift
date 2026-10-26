import FrogCore
import XCTest

final class Base64TextTests: XCTestCase {
    func testBase64DecodeReadsTextThatWasPastedWithLineBreaks() {
        let text = String(repeating: "Frog keeps the text it decodes. ", count: 4)
        let encoded = Data(text.utf8).base64EncodedString(options: .lineLength76Characters)
        XCTAssertTrue(encoded.contains("\r\n"), "The fixture is wrapped the way mail and PEM wrap Base64")
        XCTAssertEqual(Base64Text.decoded(encoded), text)
        XCTAssertEqual(Base64Text.decoded("RnJvZw==\n"), "Frog", "A trailing line break")
        XCTAssertEqual(Base64Text.decoded("  RnJv\nZw==  \n"), "Frog")
    }

    func testBase64DecodeStillRejectsWhatIsNotBase64OrNotText() {
        XCTAssertNil(Base64Text.decoded("Rn*JvZw=="), "A stray character is reported, not skipped")
        XCTAssertNil(Base64Text.decoded("RnJvZw"), "Missing padding")
        XCTAssertNil(Base64Text.decoded(Data([0xFF, 0xFE, 0x00]).base64EncodedString()), "Bytes that are not UTF-8")
        XCTAssertEqual(Base64Text.decoded(" \n"), "", "Blank input decodes to nothing")
    }

    func testEncodingRoundTrips() {
        XCTAssertEqual(Base64Text.encoded("Frog"), "RnJvZw==")
        XCTAssertEqual(Base64Text.decoded(Base64Text.encoded("Grüße 🐸")), "Grüße 🐸")
    }
}
