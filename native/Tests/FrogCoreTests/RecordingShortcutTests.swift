import XCTest
@testable import FrogCore

final class RecordingShortcutTests: XCTestCase {
    func testHoldStartsOnPressStopsOnReleaseAndIgnoresOtherRules() {
        let rule = UUID(), other = UUID()
        XCTAssertEqual(RecordingShortcut.action(mode: .hold, pressed: true, target: rule, active: nil), .start)
        XCTAssertNil(RecordingShortcut.action(mode: .hold, pressed: true, target: rule, active: rule))
        XCTAssertEqual(RecordingShortcut.action(mode: .hold, pressed: false, target: rule, active: rule), .stop)
        XCTAssertNil(RecordingShortcut.action(mode: .hold, pressed: false, target: other, active: rule))
    }
    func testToggleStartsAndStopsOnPressAndCannotStealRecording() {
        let rule = UUID(), other = UUID()
        XCTAssertNil(RecordingShortcut.action(mode: .toggle, pressed: false, target: rule, active: nil))
        XCTAssertEqual(RecordingShortcut.action(mode: .toggle, pressed: true, target: rule, active: nil), .start)
        XCTAssertEqual(RecordingShortcut.action(mode: .toggle, pressed: true, target: rule, active: rule), .stop)
        XCTAssertNil(RecordingShortcut.action(mode: .toggle, pressed: true, target: other, active: rule))
    }
}
