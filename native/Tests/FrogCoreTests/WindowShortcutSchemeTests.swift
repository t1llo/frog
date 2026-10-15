import XCTest
@testable import FrogCore

final class WindowShortcutSchemeTests: XCTestCase {
    private let controlOption: UInt32 = 4096 | 2048
    private var leftArrow: Hotkey { Hotkey(keyCode: 123, modifiers: controlOption) }
    private var delete: Hotkey { Hotkey(keyCode: 51, modifiers: controlOption) }
    private var commandTab: Hotkey { Hotkey(keyCode: 48, modifiers: 256) }

    private func apply(_ configuration: Configuration, taken: Set<Hotkey> = []) -> WindowShortcutScheme.Result {
        WindowShortcutScheme.apply(to: configuration, groups: [.simple], taken: taken)
    }

    private func layoutRule(_ action: WindowAction, in configuration: Configuration) -> Rule? {
        configuration.rules.first { $0.category == .window && $0.action?.windowAction == action }
    }

    private func display(_ key: Hotkey) -> String { "\(key.keyCode)/\(key.modifiers)" }

    func testEmptyConfigurationGetsTheWholeScheme() throws {
        let result = apply(Configuration())
        XCTAssertEqual(WindowShortcutScheme.actions.count, 18)
        XCTAssertEqual(result.added.count, 19)
        XCTAssertEqual(result.skipped, [])
        for (action, key) in WindowShortcutScheme.actions {
            let rule = try XCTUnwrap(layoutRule(action, in: result.configuration), action.title)
            XCTAssertEqual(rule.id, action.rule.id)
            XCTAssertEqual(rule.hotkey, key)
            XCTAssertTrue(rule.enabled)
            XCTAssertTrue(result.added.contains(action.title))
        }
        for action in [WindowAction.minimize, .toggleFullScreen, .centeredSmall, .centeredMedium, .centeredLarge] {
            XCTAssertNil(layoutRule(action, in: result.configuration), action.title)
        }
        XCTAssertEqual(result.configuration.preferences.toolkitSettings.windows?.shortcuts[WindowCommand.cheatSheet.rawValue],
                       Hotkey(keyCode: 44, modifiers: controlOption))
        XCTAssertTrue(result.added.contains(WindowCommand.cheatSheet.title))
        XCTAssertNoThrow(try ConfigurationFile.validate(result.configuration))
        XCTAssertEqual(result.summary(display: display), "Added 19 shortcuts.")

        let again = apply(result.configuration)
        XCTAssertEqual(again.added, [])
        XCTAssertEqual(again.configuration, result.configuration)
        XCTAssertEqual(again.summary(display: display), "Every suggested shortcut is already assigned or in use.")
    }

    func testAssignedActionsAreNeverChanged() {
        var configuration = Configuration()
        var own = WindowAction.leftHalf.rule
        own.hotkey = Hotkey(keyCode: 0, modifiers: controlOption); own.enabled = true
        var disabled = WindowAction.maximize.rule
        disabled.hotkey = Hotkey(keyCode: 46, modifiers: controlOption); disabled.enabled = false
        let empty = WindowAction.center.rule
        configuration.rules += [own, disabled, empty]
        configuration.preferences.ensureToolkit()
        var windows = WindowPreferences()
        windows.shortcuts[WindowCommand.cheatSheet.rawValue] = Hotkey(keyCode: 1, modifiers: controlOption)
        configuration.preferences.toolkit?.windows = windows

        let result = apply(configuration)
        XCTAssertEqual(layoutRule(.leftHalf, in: result.configuration), own)
        XCTAssertEqual(layoutRule(.maximize, in: result.configuration), disabled)
        XCTAssertEqual(layoutRule(.center, in: result.configuration)?.hotkey, WindowShortcutScheme.actions[.center])
        XCTAssertEqual(layoutRule(.center, in: result.configuration)?.enabled, true)
        XCTAssertEqual(result.configuration.rules.filter { $0.action?.windowAction == .center }.count, 1)
        XCTAssertEqual(result.configuration.preferences.toolkitSettings.windows?.shortcuts[WindowCommand.cheatSheet.rawValue],
                       Hotkey(keyCode: 1, modifiers: controlOption))
        XCTAssertFalse(result.added.contains(WindowAction.leftHalf.title))
        XCTAssertFalse(result.added.contains(WindowAction.maximize.title))
        XCTAssertFalse(result.added.contains(WindowCommand.cheatSheet.title))
        XCTAssertEqual(result.skipped, [])
        XCTAssertEqual(result.added.count, 16)
    }

    func testUsedCombinationsAreSkippedAndReported() throws {
        var configuration = Configuration()
        configuration.rules.append(Rule(name: "Text", instructions: "test", hotkey: leftArrow))
        configuration.preferences.setFeature(.commandBar, enabled: true)
        let switcher = Hotkey(keyCode: 36, modifiers: controlOption)
        let result = apply(configuration, taken: [switcher, Hotkey(keyCode: 36, modifiers: controlOption | 512)])
        XCTAssertEqual(result.skipped, [WindowShortcutScheme.Skip(title: WindowAction.leftHalf.title, hotkey: leftArrow),
                                        WindowShortcutScheme.Skip(title: WindowAction.maximize.title, hotkey: switcher)])
        XCTAssertEqual(result.added.count, 17)
        XCTAssertNil(layoutRule(.leftHalf, in: result.configuration))
        XCTAssertNoThrow(try ConfigurationFile.validate(result.configuration))
    }

    func testARuleOfASwitchedOffFeatureStillBlocksItsShortcut() throws {
        var configuration = Configuration()
        configuration.preferences.setFeature(.writing, enabled: false)
        configuration.rules.append(Rule(name: "Text", instructions: "test", hotkey: leftArrow))
        let result = apply(configuration)
        XCTAssertEqual(result.skipped.map(\.title), [WindowAction.leftHalf.title])
        XCTAssertNoThrow(try ConfigurationFile.validate(result.configuration))
    }

    func testCancelRecordingShortcutBlocksEvenWhileDictationIsOff() throws {
        var configuration = Configuration()
        configuration.preferences.setFeature(.dictation, enabled: false)
        var workflow = WorkflowPreferences(); workflow.cancelRecordingHotkey = delete
        configuration.preferences.workflows = workflow
        let result = apply(configuration)
        XCTAssertEqual(result.skipped.map(\.title), [WindowAction.restore.title])
        XCTAssertNoThrow(try ConfigurationFile.validate(result.configuration))
    }

    /// Each shortcut source `ConfigurationFile.validate` claims, on one scheme combination, on and off.
    /// A source added to validate later must be added here and to `usedShortcuts`.
    func testUsedShortcutsMirrorValidation() throws {
        let key = leftArrow
        let sources: [(String, (inout Configuration, Bool) -> Void)] = [
            ("command bar", { configuration, on in
                configuration.preferences.setFeature(.commandBar, enabled: on)
                configuration.preferences.toolkit?.commandBarHotkey = key
            }),
            ("menu bar", { configuration, on in
                configuration.preferences.setFeature(.menuBar, enabled: on)
                var menuBar = MenuBarPreferences(); menuBar.hotkey = key
                configuration.preferences.toolkit?.menuBar = menuBar
            }),
            ("shortcut panel", { configuration, on in
                var workflow = configuration.preferences.workflowSettings; workflow.shortcutPanelHotkey = on ? key : nil
                configuration.preferences.workflows = workflow
            }),
            ("cancel recording", { configuration, on in
                var workflow = configuration.preferences.workflowSettings; workflow.cancelRecordingHotkey = on ? key : nil
                configuration.preferences.workflows = workflow
            }),
            ("clipboard history", { configuration, on in
                configuration.preferences.setFeature(.clipboard, enabled: on)
                var workflow = configuration.preferences.workflowSettings; workflow.clipboardHistoryHotkey = key
                configuration.preferences.workflows = workflow
            }),
            ("rule", { configuration, on in
                configuration.rules.append(Rule(name: "Text", instructions: "test", hotkey: key, enabled: on))
            }),
            ("window command", { configuration, on in
                configuration.preferences.setFeature(.windows, enabled: on)
                var windows = WindowPreferences(); windows.shortcuts[WindowCommand.cheatSheet.rawValue] = key
                configuration.preferences.toolkit?.windows = windows
            }),
        ]
        for (name, set) in sources {
            for on in [true, false] {
                var configuration = Configuration()
                configuration.preferences.ensureToolkit()
                set(&configuration, on)
                XCTAssertNoThrow(try ConfigurationFile.validate(configuration), "\(name) \(on)")
                XCTAssertEqual(WindowShortcutScheme.usedShortcuts(configuration).contains(key), on, "\(name) \(on)")
                let result = apply(configuration)
                XCTAssertEqual(result.skipped.map(\.title) == [WindowAction.leftHalf.title], on, "\(name) \(on)")
                XCTAssertEqual(layoutRule(.leftHalf, in: result.configuration)?.hotkey == key, !on, "\(name) \(on)")
                XCTAssertNoThrow(try ConfigurationFile.validate(result.configuration), "\(name) \(on)")
            }
        }
    }

    func testResultValidates() throws {
        XCTAssertNoThrow(try ConfigurationFile.validate(apply(Configuration()).configuration))
        var configuration = Configuration()
        configuration.preferences.ensureToolkit()
        configuration.preferences.setFeature(.commandBar, enabled: true)
        configuration.preferences.toolkit?.commandBarHotkey = Hotkey(keyCode: 124, modifiers: controlOption)
        configuration.preferences.setFeature(.menuBar, enabled: true)
        var menuBar = MenuBarPreferences(); menuBar.hotkey = Hotkey(keyCode: 126, modifiers: controlOption)
        configuration.preferences.toolkit?.menuBar = menuBar
        configuration.preferences.setFeature(.windows, enabled: true)
        var windows = WindowPreferences(); windows.shortcuts[WindowCommand.cheatSheet.rawValue] = Hotkey(keyCode: 125, modifiers: controlOption)
        configuration.preferences.toolkit?.windows = windows
        var workflow = WorkflowPreferences()
        workflow.shortcutPanelHotkey = Hotkey(keyCode: 32, modifiers: controlOption)
        workflow.cancelRecordingHotkey = delete
        workflow.clipboardHistoryEnabled = true
        workflow.clipboardHistoryHotkey = Hotkey(keyCode: 34, modifiers: controlOption)
        configuration.preferences.workflows = workflow
        configuration.rules.append(Rule(name: "Text", instructions: "test", hotkey: leftArrow))
        XCTAssertNoThrow(try ConfigurationFile.validate(configuration))
        let result = apply(configuration, taken: [Hotkey(keyCode: 8, modifiers: controlOption)])
        XCTAssertEqual(Set(result.skipped.map(\.title)), Set([WindowAction.leftHalf, .rightHalf, .topHalf, .bottomHalf, .topLeft, .topRight, .restore, .center].map(\.title)))
        XCTAssertNoThrow(try ConfigurationFile.validate(result.configuration))
    }

    func testResultLineNamesActionsByTitle() {
        let maximize = WindowShortcutScheme.Skip(title: WindowAction.maximize.title, hotkey: Hotkey(keyCode: 36, modifiers: controlOption))
        var result = WindowShortcutScheme.Result(configuration: Configuration(), added: Array(repeating: "x", count: 17), skipped: [maximize])
        XCTAssertEqual(result.summary(display: { _ in "⌃⌥↩" }), "Added 17 shortcuts. Skipped 1 already in use: \(WindowAction.maximize.title) (⌃⌥↩).")
        result.skipped = Array(repeating: maximize, count: 5)
        XCTAssertEqual(result.summary(display: { _ in "K" }),
                       "Added 17 shortcuts. Skipped 5 already in use: \(maximize.title) (K), \(maximize.title) (K), \(maximize.title) (K) and 2 more.")
        result.added = []
        XCTAssertEqual(result.summary(display: { _ in "K" }), "Every suggested shortcut is already assigned or in use.")
    }
}
