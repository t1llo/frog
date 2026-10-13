import AppKit
import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class AppearanceSettingsTests: XCTestCase {
    func testPickedColourIsSavedAsItsNearestHex() {
        XCTAssertEqual(AppearanceSettingsView.hex(of: NSColor(srgbRed: 0x44 / 255.0, green: 0x55 / 255.0, blue: 0x66 / 255.0, alpha: 1)), "445566")
        // A colour converted from another colour space rarely lands exactly on an 8-bit step.
        XCTAssertEqual(AppearanceSettingsView.hex(of: NSColor(srgbRed: 127.6 / 255, green: 0.4 / 255, blue: 254.6 / 255, alpha: 1)), "8000FF")
    }
}
