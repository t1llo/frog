import XCTest
import FrogCore
@testable import FrogApp

/// How window command shortcuts are registered, checked and routed, decided without a window.
@MainActor final class WindowShortcutRoutingTests: XCTestCase {
    private let slash = Hotkey(keyCode: 44, modifiers: 4096 | 2048)

    private func configuration(cheatSheet key: Hotkey?, windows: Bool) -> Configuration {
        var configuration = Configuration()
        configuration.preferences.ensureToolkit()
        configuration.preferences.setFeature(.windows, enabled: windows)
        var settings = WindowPreferences()
        settings.shortcuts[WindowCommand.cheatSheet.rawValue] = key
        configuration.preferences.toolkit?.windows = settings
        return configuration
    }

    func testWindowCommandShortcutsRegisterOnlyWhileWindowsIsOn() {
        let on = AppModel.hotkeyRules(for: configuration(cheatSheet: slash, windows: true))
        XCTAssertEqual(on.first { $0.id == WindowCommand.cheatSheet.id }?.hotkey, slash)
        XCTAssertFalse(AppModel.hotkeyRules(for: configuration(cheatSheet: slash, windows: false)).contains { $0.id == WindowCommand.cheatSheet.id })
        XCTAssertFalse(AppModel.hotkeyRules(for: configuration(cheatSheet: nil, windows: true)).contains { $0.id == WindowCommand.cheatSheet.id })
    }

    func testChangingAWindowCommandShortcutRegistersAgain() {
        // One base, since every new configuration has preset rules with new ids.
        let previous = configuration(cheatSheet: slash, windows: true)
        func with(_ key: Hotkey?, windows: Bool = true) -> Configuration {
            var changed = previous
            changed.preferences.toolkit?.windows?.shortcuts[WindowCommand.cheatSheet.rawValue] = key
            changed.preferences.setFeature(.windows, enabled: windows)
            return changed
        }
        XCTAssertFalse(AppModel.registersShortcutsAgain(previous: previous, current: with(slash), failed: false, holding: false))
        XCTAssertTrue(AppModel.registersShortcutsAgain(previous: previous, current: with(Hotkey(keyCode: 44, modifiers: 4096 | 256)), failed: false, holding: false))
        XCTAssertTrue(AppModel.registersShortcutsAgain(previous: previous, current: with(nil), failed: false, holding: false))
        XCTAssertTrue(AppModel.registersShortcutsAgain(previous: previous, current: with(slash, windows: false), failed: false, holding: false))
        // Switched off, the shortcut is not registered either way.
        XCTAssertFalse(AppModel.registersShortcutsAgain(previous: with(slash, windows: false), current: with(nil, windows: false), failed: false, holding: false))
    }

    func testAWindowCommandOnTheSwitcherShortcutStopsTheSwitcher() {
        let commandTab = Hotkey(keyCode: 48, modifiers: 256)
        var configuration = configuration(cheatSheet: commandTab, windows: true)
        configuration.preferences.windowSwitcherEnabled = true
        configuration.preferences.toolkit?.windowSwitcherHotkey = commandTab
        guard case .stop = AppModel.windowSwitcherStep(configuration, status: "Ready", ready: true) else {
            return XCTFail("A window command on the switcher's shortcut stops the switcher")
        }
        configuration.preferences.setFeature(.windows, enabled: false)
        XCTAssertEqual(AppModel.windowSwitcherStep(configuration, status: "Ready", ready: true), .configure)
        XCTAssertEqual(AppModel.windowSwitcherChords(configuration.preferences), [commandTab, Hotkey(keyCode: 48, modifiers: 256 | 512)])
        configuration.preferences.windowSwitcherEnabled = false
        XCTAssertEqual(AppModel.windowSwitcherChords(configuration.preferences), [])
    }

    func testDuplicateWindowCommandShortcutIsRejected() throws {
        var configuration = configuration(cheatSheet: Hotkey(keyCode: 49, modifiers: 4096 | 2048), windows: true)
        configuration.preferences.setFeature(.commandBar, enabled: true)
        XCTAssertThrowsError(try ConfigurationFile.validate(configuration)) {
            XCTAssertEqual($0.localizedDescription, "The window shortcut for \(WindowCommand.cheatSheet.title) conflicts with another shortcut.")
        }
        configuration.preferences.setFeature(.windows, enabled: false)
        XCTAssertNoThrow(try ConfigurationFile.validate(configuration))
    }

    func testAnInvalidCommandShortcutIsRejectedEvenWhileWindowsIsOff() {
        let shiftOnly = configuration(cheatSheet: Hotkey(keyCode: 0, modifiers: 512), windows: false)
        XCTAssertThrowsError(try ConfigurationFile.validate(shiftOnly))
        var unknown = configuration(cheatSheet: nil, windows: true)
        unknown.preferences.toolkit?.windows?.shortcuts["fromANewerFrog"] = Hotkey(keyCode: 0, modifiers: 512)
        XCTAssertNoThrow(try ConfigurationFile.validate(unknown), "A command this version does not know is left alone")
    }

    func testTheControllerRunsOnlyWhileActiveAndWindowsIsOn() {
        let controller = WindowLayoutController(manager: WindowManager(access: AXWindowAccess()), displays: { [] },
                                                readMacOS: { MacWindowManagerSettings() })
        controller.configure(configuration(cheatSheet: slash, windows: true), active: false)
        XCTAssertFalse(controller.running)
        controller.configure(configuration(cheatSheet: slash, windows: false), active: true)
        XCTAssertFalse(controller.running)
        controller.configure(configuration(cheatSheet: slash, windows: true), active: true)
        XCTAssertTrue(controller.running)
        controller.handle(.cheatSheet, pressed: false)
        controller.stop()
    }
}
