import XCTest
import FrogCore
@testable import FrogApp

/// The status loop asks every second what the window switcher should do. While a
/// shortcut takes its chord, stopping it again would publish Off and then the
/// conflict once more, so the page would redraw every second for nothing.
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

    private let ready = WindowSwitcherStatus.ready(Hotkey(keyCode: 48, modifiers: 256))

    private func message(_ configuration: Configuration) throws -> WindowSwitcherStatus {
        guard case .stop(let reason) = WindowSwitcherPlugin.step(configuration, status: ready) else {
            XCTFail("A conflicting shortcut stops the switcher"); return .off
        }
        return reason
    }

    func testConflictStopsTheSwitcherOnceAndThenLeavesItAlone() throws {
        let configuration = conflicting(commandTab)
        let message = try message(configuration)
        XCTAssertEqual(message, .conflict(commandTab))
        XCTAssertTrue(message.isIssue)
        XCTAssertEqual(WindowSwitcherPlugin.step(configuration, status: message), .none,
                       "A conflict already shown is not stopped and published again on every tick")
    }

    func testConflictStopsTheSwitcherAgainWhenTheStatusSaysSomethingElse() throws {
        let configuration = conflicting(commandTab)
        let message = try message(configuration)
        XCTAssertEqual(WindowSwitcherPlugin.step(configuration, status: .off), .stop(message))
    }

    func testReverseCyclingChordCountsAsAConflict() throws {
        let configuration = conflicting(Hotkey(keyCode: 48, modifiers: 256 | 512))
        XCTAssertEqual(try message(configuration), .conflict(commandTab))
    }

    func testWithoutAConflictOrWithTheSwitcherOffItIsConfigured() {
        var configuration = conflicting(Hotkey(keyCode: 8, modifiers: 256))
        XCTAssertEqual(WindowSwitcherPlugin.step(configuration, status: ready), .configure)
        configuration = conflicting(commandTab)
        configuration.preferences.windowSwitcherEnabled = false
        XCTAssertEqual(WindowSwitcherPlugin.step(configuration, status: .off), .configure)
    }

    func testDisabledRuleOrFeatureDoesNotConflict() {
        var configuration = conflicting(commandTab)
        configuration.rules[0].enabled = false
        XCTAssertEqual(WindowSwitcherPlugin.step(configuration, status: ready), .configure)
        configuration = conflicting(commandTab)
        configuration.preferences.setFeature(.writing, enabled: false)
        XCTAssertTrue(configuration.preferences.windowSwitcherEnabled)
        XCTAssertEqual(WindowSwitcherPlugin.step(configuration, status: ready), .configure)
    }
}
