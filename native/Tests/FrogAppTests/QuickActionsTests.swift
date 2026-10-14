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
}
