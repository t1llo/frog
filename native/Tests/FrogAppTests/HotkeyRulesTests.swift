import XCTest
import FrogCore
@testable import FrogApp

/// Saving preferences registers the global shortcuts again only when what they register changes:
/// registering forgets a shortcut that is held down, and a hold-mode recording then misses its release.
@MainActor
final class HotkeyRulesTests: XCTestCase {
    func testSettingsThatRegisterNoShortcutLeaveTheShortcutsAsTheyAre() {
        var configuration = Configuration()
        var launcher = Rule(name: "Open Notes", hotkey: Hotkey(keyCode: 45, modifiers: 256 | 2048))
        launcher.action = RuleAction(category: .application)
        configuration.rules = [launcher]
        // Once the Shortcuts feature has been switched, its setting is written for good.
        configuration.preferences.setFeature(.applicationShortcuts, enabled: true)
        let registered = AppModel.hotkeyRules(for: configuration)
        XCTAssertEqual(registered.map(\.id).first, launcher.id)

        var changed = configuration
        var workflow = changed.preferences.workflowSettings
        workflow.microphoneID = "fixture-microphone"
        changed.preferences.workflows = workflow
        XCTAssertEqual(AppModel.hotkeyRules(for: changed), registered, "Choosing a microphone")

        changed = configuration
        var menuBar = MenuBarPreferences(); menuBar.autoHide = false
        changed.preferences.toolkit?.menuBar = menuBar
        XCTAssertEqual(AppModel.hotkeyRules(for: changed), registered, "Menu bar layout")

        changed = configuration
        changed.preferences.toolkit?.windowSwitcherHotkey = Hotkey(keyCode: 48, modifiers: 2048)
        XCTAssertEqual(AppModel.hotkeyRules(for: changed), registered, "The window switcher listens for its own key")
    }

    func testSettingsThatChangeAShortcutRegisterThemAgain() {
        var configuration = Configuration()
        var launcher = Rule(name: "Open Notes", hotkey: Hotkey(keyCode: 45, modifiers: 256 | 2048))
        launcher.action = RuleAction(category: .application)
        configuration.rules = [launcher]
        configuration.preferences.setFeature(.applicationShortcuts, enabled: true)
        let registered = AppModel.hotkeyRules(for: configuration)

        var changed = configuration
        changed.preferences.setFeature(.applicationShortcuts, enabled: false)
        XCTAssertFalse(AppModel.hotkeyRules(for: changed).contains { $0.id == launcher.id })

        changed = configuration
        changed.preferences.setFeature(.commandBar, enabled: true)
        let withCommandBar = AppModel.hotkeyRules(for: changed)
        XCTAssertNotEqual(withCommandBar, registered)
        changed.preferences.toolkit?.commandBarHotkey = Hotkey(keyCode: 49, modifiers: 256 | 512)
        XCTAssertNotEqual(AppModel.hotkeyRules(for: changed), withCommandBar)

        changed = configuration
        var workflow = changed.preferences.workflowSettings
        workflow.shortcutPanelHotkey = Hotkey(keyCode: 1, modifiers: 256 | 2048)
        changed.preferences.workflows = workflow
        XCTAssertNotEqual(AppModel.hotkeyRules(for: changed), registered)

        changed = configuration
        changed.preferences.setFeature(.clipboard, enabled: !(configuration.preferences.workflowSettings.clipboardHistoryEnabled == true))
        XCTAssertNotEqual(AppModel.hotkeyRules(for: changed), registered)
    }

    func testOnlyAChangedShortcutOrAnEarlierFailureRegistersTheShortcutsAgain() {
        var configuration = Configuration()
        var launcher = Rule(name: "Open Notes", hotkey: Hotkey(keyCode: 45, modifiers: 256 | 2048))
        launcher.action = RuleAction(category: .application)
        configuration.rules = [launcher]
        // Once the Shortcuts feature has been switched, its setting is written for good.
        configuration.preferences.setFeature(.applicationShortcuts, enabled: true)

        var changed = configuration
        var workflow = changed.preferences.workflowSettings
        workflow.microphoneID = "fixture-microphone"
        changed.preferences.workflows = workflow
        XCTAssertFalse(AppModel.registersShortcutsAgain(previous: configuration, current: changed, failed: false), "Choosing a microphone")

        changed = configuration
        var menuBar = MenuBarPreferences(); menuBar.autoHide = false
        changed.preferences.toolkit?.menuBar = menuBar
        XCTAssertFalse(AppModel.registersShortcutsAgain(previous: configuration, current: changed, failed: false), "Menu bar layout")

        changed = configuration
        changed.preferences.toolkit?.commandBarHotkey = Hotkey(keyCode: 49, modifiers: 256 | 512)
        changed.preferences.setFeature(.commandBar, enabled: true)
        XCTAssertTrue(AppModel.registersShortcutsAgain(previous: configuration, current: changed, failed: false), "A new shortcut")

        XCTAssertTrue(AppModel.registersShortcutsAgain(previous: configuration, current: configuration, failed: true), "A shortcut that could not be registered is tried again")
    }
}
