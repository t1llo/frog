import XCTest
@testable import FrogCore

final class SystemSettingsCatalogTests: XCTestCase {
    func testCommonNaturalLanguageQueriesFindTheRightSettings() {
        let records = SystemSettingsCatalog.defaults.map(\.record)
        for (query, title) in [
            ("change my desktop wallpaper", "Wallpaper"), ("desktop background", "Wallpaper"),
            ("where can I change my wallpaper?", "Wallpaper"), ("Do not disturb?", "Focus"),
            ("change desktop", "Desktop & Dock"), ("wallpaper", "Wallpaper"),
            ("wifi", "Wi-Fi"), ("open wi fi settings", "Wi-Fi"), ("wireless network", "Wi-Fi"),
            ("audio", "Sound"), ("change audio output", "Sound"), ("microphone input", "Sound"),
            ("privacy settings", "Privacy & Security"), ("privacy camera", "Camera Permissions"),
            ("screen recording permission", "Screen Recording Permissions"),
            ("full disk access", "Full Disk Access"), ("turn on dark mode", "Appearance"),
            ("change screen resolution", "Displays"), ("startup apps", "Login Items & Extensions"),
            ("keyboard shortcuts", "Keyboard"), ("do not disturb", "Focus"),
            ("time zone", "Date & Time"), ("backup", "Time Machine")
        ] {
            XCTAssertEqual(CommandSearch.results(records, query: query).first?.title, title, query)
        }
    }

    func testCatalogueHasDistinctDestinationsAndEveryTitleIsSearchable() {
        let settings = SystemSettingsCatalog.defaults
        XCTAssertGreaterThanOrEqual(settings.count, 50)
        XCTAssertEqual(Set(settings.map { $0.record.id }).count, settings.count)
        for setting in settings {
            XCTAssertTrue(CommandSearch.results(settings.map(\.record), query: setting.record.title).contains(setting.record))
            XCTAssertEqual(setting.destinations.first?.scheme, "x-apple.systempreferences")
            XCTAssertEqual(setting.destinations.last?.absoluteString, "x-apple.systempreferences:")
        }
        XCTAssertEqual(settings.first { $0.record.title == "Camera Permissions" }?.destinations.first?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    func testCommandContextDoesNotChangeLiteralAppAndFileSearch() {
        let literal = SearchRecord(id: "file", title: "Wallpaper")
        let settings = SystemSettingsCatalog.defaults.map(\.record)
        let results = CommandSearch.results([literal] + settings, query: "change my wallpaper")
        XCTAssertEqual(results.first?.title, "Wallpaper")
        XCTAssertFalse(results.contains(literal))
        XCTAssertTrue(CommandSearch.results(settings, query: "change").isEmpty)
    }
}
