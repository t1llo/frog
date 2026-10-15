import XCTest
@testable import FrogCore

final class MacWindowManagerSettingsTests: XCTestCase {
    func testAbsentKeysMeanTilingOnFromMacOS15AndStageManagerOff() {
        XCTAssertEqual(MacWindowManagerSettings(values: [:], osMajorVersion: 14), MacWindowManagerSettings())
        XCTAssertEqual(MacWindowManagerSettings(values: [:], osMajorVersion: 15),
                       MacWindowManagerSettings(stageManager: false, edgeTiling: true, topEdgeTiling: true, optionAccelerator: true))
        XCTAssertEqual(MacWindowManagerSettings(values: [:], osMajorVersion: 26).edgeTiling, true)
    }

    func testExplicitValuesWin() {
        let off = ["EnableTilingByEdgeDrag": false, "EnableTopTilingByEdgeDrag": false, "EnableTilingOptionAccelerator": false]
        XCTAssertEqual(MacWindowManagerSettings(values: off, osMajorVersion: 15), MacWindowManagerSettings())
        let mixed = MacWindowManagerSettings(values: ["EnableTopTilingByEdgeDrag": false], osMajorVersion: 15)
        XCTAssertTrue(mixed.edgeTiling)
        XCTAssertFalse(mixed.topEdgeTiling)
        XCTAssertTrue(mixed.optionAccelerator)
        XCTAssertTrue(MacWindowManagerSettings(values: ["EnableTilingByEdgeDrag": true], osMajorVersion: 14).edgeTiling)
    }

    func testStageManagerOn() {
        for version in [14, 15] {
            let settings = MacWindowManagerSettings(values: ["GloballyEnabled": true], osMajorVersion: version)
            XCTAssertTrue(settings.stageManager)
            XCTAssertEqual(settings.edgeTiling, version >= 15)
        }
        XCTAssertFalse(MacWindowManagerSettings(values: ["GloballyEnabled": false], osMajorVersion: 15).stageManager)
        XCTAssertEqual(MacWindowManagerSettings.keys.count, 4)
    }
}
