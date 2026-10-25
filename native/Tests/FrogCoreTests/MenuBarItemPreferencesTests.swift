import XCTest
@testable import FrogCore

/// The looks of Frog's menu-bar items are portable: they round-trip through both files, and a
/// look Frog does not know falls back to its default instead of refusing the configuration.
final class MenuBarItemPreferencesTests: XCTestCase {
    func testTheMenuBarChoicesRoundTripThroughTheTextFile() throws {
        let companion = try TextConfiguration.companion(Configuration())
        let text = """
        usage.menu-bar-style = segments
        usage.menu-bar-palette = spectrum
        system-monitor.menu-bar = true
        system-monitor.menu-bar-style = columns
        system-monitor.menu-bar-palette = level
        stay-awake.menu-bar = true
        stay-awake.menu-bar-style = time

        """
        let loaded = try TextConfiguration.decode(text, companion: companion)
        let toolkit = try XCTUnwrap(loaded.preferences.toolkit)
        XCTAssertEqual(toolkit.usage?.menuBarStyle, "segments")
        XCTAssertEqual(toolkit.usage?.menuBarPalette, "spectrum")
        XCTAssertEqual(toolkit.systemMonitor, SystemMonitorPreferences(menuBarItem: true, menuBarStyle: "columns", menuBarPalette: "level"))
        XCTAssertEqual(toolkit.stayAwake, StayAwakePreferences(menuBarItem: true, menuBarStyle: "time"))
        let rendered = try TextConfiguration.render(loaded)
        for line in text.split(separator: "\n") { XCTAssertTrue(rendered.contains(line), "\(line) is written back") }

        // Unset, they read as the defaults: today's numbers, no extra items.
        let defaults = try XCTUnwrap(TextConfiguration.decode("usage.range = 7d\n", companion: companion).preferences.toolkit)
        XCTAssertEqual(defaults.usage?.menuBarStyle, "numbers")
        XCTAssertEqual(defaults.usage?.menuBarPalette, "clean")
        XCTAssertFalse(defaults.systemMonitor?.menuBarItem ?? false)
        XCTAssertFalse(defaults.stayAwake?.menuBarItem ?? false)
    }

    func testAnUnknownLookIsRefusedInTheTextFileWithItsLine() throws {
        let companion = try TextConfiguration.companion(Configuration())
        XCTAssertThrowsError(try TextConfiguration.decode("system-monitor.menu-bar-style = dial\n", companion: companion)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("config:1: system-monitor.menu-bar-style: choose numbers, segments, bars, columns"),
                          $0.localizedDescription)
        }
        XCTAssertThrowsError(try UsageDisplayPreferences(menuBarStyle: "dial").validate())
    }

    func testAnUnknownLookInJSONFallsBackToItsDefault() throws {
        let monitor = try JSONDecoder().decode(SystemMonitorPreferences.self,
                                               from: Data(#"{"menuBarItem":true,"menuBarStyle":"dial","menuBarPalette":"neon"}"#.utf8))
        XCTAssertEqual(monitor, SystemMonitorPreferences(menuBarItem: true))
        let awake = try JSONDecoder().decode(StayAwakePreferences.self, from: Data(#"{"menuBarStyle":"sparkles"}"#.utf8))
        XCTAssertEqual(awake, StayAwakePreferences())
        XCTAssertEqual(try JSONDecoder().decode(SystemMonitorPreferences.self, from: Data("{}".utf8)), SystemMonitorPreferences())
        // Saved before the looks existed, usage choices load with today's numbers.
        let usage = try JSONDecoder().decode(UsageDisplayPreferences.self, from: Data(#"{"provider":"Claude"}"#.utf8))
        XCTAssertEqual(usage.menuBarStyle, "numbers")
        XCTAssertEqual(usage.menuBarPalette, "clean")
    }

    func testTheItemsSurviveAWholeConfigurationRoundTrip() throws {
        var configuration = Configuration()
        configuration.preferences.ensureToolkit()
        configuration.preferences.toolkit?.systemMonitor = SystemMonitorPreferences(menuBarItem: true, menuBarStyle: "bars")
        configuration.preferences.toolkit?.stayAwake = StayAwakePreferences(menuBarItem: true, menuBarStyle: "icon")
        let decoded = try ConfigurationFile.decode(ConfigurationFile.encode(configuration))
        XCTAssertEqual(decoded.preferences.toolkit?.systemMonitor, configuration.preferences.toolkit?.systemMonitor)
        XCTAssertEqual(decoded.preferences.toolkit?.stayAwake, configuration.preferences.toolkit?.stayAwake)
    }
}
