import XCTest
import FrogCore
@testable import FrogApp

/// The status loop asks every second what the window switcher should do. While a
/// shortcut takes its chord, stopping it again would publish "Off" and then the
/// conflict once more, so Settings would redraw twice a second for nothing.
@MainActor
final class WindowSwitcherConflictTests: XCTestCase {
    private let commandTab = Hotkey(keyCode: 48, modifiers: 256)

    private func conflicting(_ hotkey: Hotkey) -> Configuration {
        var configuration = Configuration()
        var toolkit = ToolkitPreferences()
        toolkit.windowSwitcherHotkey = commandTab
        configuration.preferences.toolkit = toolkit
        configuration.rules = [Rule(name: "Conflict", instructions: "test", hotkey: hotkey)]
        return configuration
    }

    private func message(_ configuration: Configuration) throws -> String {
        guard case .stop(let message) = AppModel.windowSwitcherStep(configuration, status: "Ready", ready: true) else {
            XCTFail("A conflicting shortcut stops the switcher"); return ""
        }
        return message
    }

    func testConflictStopsTheSwitcherOnceAndThenLeavesItAlone() throws {
        let configuration = conflicting(commandTab)
        let message = try message(configuration)
        XCTAssertTrue(message.contains("change it to enable window switching"))
        XCTAssertEqual(AppModel.windowSwitcherStep(configuration, status: message, ready: false), .none,
                       "A conflict already shown is not stopped and published again on every tick")
    }

    func testConflictStopsTheSwitcherAgainWhenTheStatusSaysSomethingElse() throws {
        let configuration = conflicting(commandTab)
        let message = try message(configuration)
        XCTAssertEqual(AppModel.windowSwitcherStep(configuration, status: "Off — macOS app switcher", ready: false), .stop(message))
        XCTAssertEqual(AppModel.windowSwitcherStep(configuration, status: message, ready: true), .stop(message))
    }

    func testReverseCyclingChordCountsAsAConflict() throws {
        let configuration = conflicting(Hotkey(keyCode: 48, modifiers: 256 | 512))
        XCTAssertNotEqual(try message(configuration), "")
    }

    func testWithoutAConflictOrWithTheSwitcherOffItIsConfigured() {
        var configuration = conflicting(Hotkey(keyCode: 8, modifiers: 256))
        XCTAssertEqual(AppModel.windowSwitcherStep(configuration, status: "Ready", ready: true), .configure)
        configuration = conflicting(commandTab)
        configuration.preferences.windowSwitcherEnabled = false
        XCTAssertEqual(AppModel.windowSwitcherStep(configuration, status: "Off — macOS app switcher", ready: false), .configure)
    }

    func testDisabledRuleOrFeatureDoesNotConflict() {
        var configuration = conflicting(commandTab)
        configuration.rules[0].enabled = false
        XCTAssertEqual(AppModel.windowSwitcherStep(configuration, status: "Ready", ready: true), .configure)
        configuration = conflicting(commandTab)
        configuration.preferences.setFeature(.writing, enabled: false)
        XCTAssertTrue(configuration.preferences.windowSwitcherEnabled)
        XCTAssertEqual(AppModel.windowSwitcherStep(configuration, status: "Ready", ready: true), .configure)
    }
}
