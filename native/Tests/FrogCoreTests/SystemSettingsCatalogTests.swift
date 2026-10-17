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

    func testEachPaneTakesTheIconSystemSettingsShows() {
        func info(icons: [String: Any]? = nil, file: String? = nil, name: String? = nil, representations: [[String: Any]] = []) -> [String: Any] {
            var info: [String: Any] = ["EXAppExtensionAttributes": ["SettingsExtensionAttributes": ["representations": representations]]]
            info["CFBundleIcons"] = icons; info["CFBundleIconFile"] = file; info["CFBundleIconName"] = name
            return info
        }
        let path = "/System/Library/ExtensionKit/Extensions/Pane.appex"
        let laptop = ["powersource.battery": true], desktop = ["powersource.battery": false]
        // Displays, Wi-Fi and most panes describe their icon in CFBundleIcons.
        let displays = info(icons: ["ISGraphicIconConfiguration": ["ISTypeIdentifier": "com.apple.graphic-icon.display"]])
        XCTAssertEqual(SystemSettingIcon.resolve(info: displays, bundlePath: path, facts: laptop), .bundle(path: path))
        // Spotlight and Time Machine name an icon of their own.
        XCTAssertEqual(SystemSettingIcon.resolve(info: info(file: "AppIcon"), bundlePath: path, facts: [:]), .bundle(path: path))
        XCTAssertEqual(SystemSettingIcon.resolve(info: info(name: "TimeMachineSettingsIcon"), bundlePath: path, facts: [:]), .bundle(path: path))
        // Battery only has the placeholder file and picks its sidebar icon by power source.
        let battery = info(file: "icon", representations: [
            ["predicate": "powersource.battery != YES", "sidebar-iconUTTypeIdentifier": "com.apple.graphic-icon.energy"],
            ["predicate": "powersource.battery == YES", "sidebar-iconUTTypeIdentifier": "com.apple.graphic-icon.battery"]])
        XCTAssertEqual(SystemSettingIcon.resolve(info: battery, bundlePath: path, facts: laptop), .type(identifier: "com.apple.graphic-icon.battery"))
        XCTAssertEqual(SystemSettingIcon.resolve(info: battery, bundlePath: path, facts: desktop), .type(identifier: "com.apple.graphic-icon.energy"))
        XCTAssertNil(SystemSettingIcon.resolve(info: battery, bundlePath: path, facts: [:]), "An unknown power source keeps the System Settings icon")
        // Conditions Frog cannot answer fall through to the bundle's own icon.
        let siri = info(file: "AppIconSiri", representations: [
            ["predicate": "supports.systemAssistantExperience == YES", "sidebar-iconUTTypeIdentifier": "com.apple.graphic-icon.intelligence"]])
        XCTAssertEqual(SystemSettingIcon.resolve(info: siri, bundlePath: path, facts: laptop), .bundle(path: path))
        // Headphones carries only the placeholder that Finder draws as a plug-in brick.
        XCTAssertNil(SystemSettingIcon.resolve(info: info(file: "icon"), bundlePath: path, facts: laptop))
        XCTAssertNil(SystemSettingIcon.resolve(info: [:], bundlePath: path, facts: laptop))

        XCTAssertNil(SystemSettingIcon.holds("powersource.battery = YES", facts: laptop))
        XCTAssertEqual(SystemSettingIcon.holds("powersource.battery == NO", facts: desktop), true)
        for icon in [SystemSettingIcon.bundle(path: path), .type(identifier: "com.apple.graphic-icon.battery")] {
            XCTAssertEqual(SystemSettingIcon.typeIdentifier(fromKey: icon.key), { if case .type(let id) = icon { return id }; return nil }())
        }
        let privacy = SystemSettingsCatalog.defaults.first { $0.record.title == "Camera Permissions" }
        XCTAssertNil(privacy?.icon)
        XCTAssertEqual(privacy?.withIcon(.bundle(path: path)).icon, .bundle(path: path))
        XCTAssertEqual(privacy?.withIcon(.bundle(path: path)).includingSearchTerms("lens", localizedTitle: "Camera").icon, .bundle(path: path))
    }
}
