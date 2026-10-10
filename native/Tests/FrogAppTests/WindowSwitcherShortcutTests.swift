import XCTest
import Carbon
import CoreGraphics
import FrogCore
@testable import FrogApp

final class WindowSwitcherShortcutTests: XCTestCase {
    func testOptionTabRoutesForwardReverseAndCommitsOnlyOnOptionRelease() throws {
        let messages = ShortcutMessages()
        let input = WindowSwitchInput(hotkey: .init(keyCode: 48, modifiers: UInt32(optionKey))) { messages.append($0) }
        XCTAssertTrue(input.receive(type: .keyDown, event: try event(48, flags: .maskCommand)) != nil)
        XCTAssertTrue(messages.actions.isEmpty, "Rebinding must leave native Command–Tab available")
        XCTAssertTrue(input.receive(type: .keyDown, event: try event(48, flags: .maskAlternate)) == nil)
        XCTAssertTrue(input.receive(type: .keyDown, event: try event(48, flags: [.maskAlternate, .maskShift])) == nil)
        _ = input.receive(type: .flagsChanged, event: try event(56, flags: .maskAlternate))
        _ = input.receive(type: .flagsChanged, event: try event(55, flags: [.maskAlternate, .maskCommand]))
        _ = input.receive(type: .flagsChanged, event: try event(55, flags: .maskAlternate))
        XCTAssertEqual(messages.actions, [.begin(backwards: false), .step(backwards: true)],
                       "Shift or an unrelated modifier release must not commit")
        _ = input.receive(type: .flagsChanged, event: try event(58, flags: []))
        _ = input.receive(type: .flagsChanged, event: try event(55, flags: []))
        XCTAssertEqual(messages.actions, [.begin(backwards: false), .step(backwards: true), .commit])
        XCTAssertTrue(input.receive(type: .keyUp, event: try event(48, down: false)) == nil)
    }

    func testControlSpaceSupportsSearchAndUnrelatedChordCancelsWithoutConsumingIt() throws {
        let messages = ShortcutMessages()
        let input = WindowSwitchInput(hotkey: .init(keyCode: 49, modifiers: UInt32(controlKey))) { messages.append($0) }
        XCTAssertTrue(input.receive(type: .keyDown, event: try event(49, flags: .maskControl)) == nil)
        XCTAssertTrue(input.receive(type: .keyUp, event: try event(49, down: false, flags: .maskControl)) == nil)
        let search = try event(0, flags: .maskControl)
        let units = Array("a".utf16)
        search.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        XCTAssertTrue(input.receive(type: .keyDown, event: search) == nil)
        XCTAssertEqual(messages.actions, [.begin(backwards: false), .search("a")])
        XCTAssertTrue(input.receive(type: .keyDown, event: try event(51, flags: .maskControl)) == nil)
        XCTAssertEqual(messages.actions.last, .deleteSearch)
        XCTAssertTrue(input.receive(type: .keyDown, event: try event(12, flags: [.maskControl, .maskAlternate])) != nil)
        XCTAssertEqual(messages.actions.last, .cancel)
        _ = input.receive(type: .flagsChanged, event: try event(59, flags: []))
        XCTAssertFalse(messages.actions.contains(.commit))
    }

    func testEverySupportedBaseModifierCombinationCommitsWhenAnyRequiredModifierIsReleased() {
        let bases: [(UInt32, CGEventFlags)] = [(UInt32(cmdKey), .maskCommand), (UInt32(optionKey), .maskAlternate), (UInt32(controlKey), .maskControl)]
        for mask in 1..<8 {
            let required = bases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let carbon = required.reduce(UInt32(0)) { $0 | $1.0 }
            let flags = required.reduce(CGEventFlags()) { $0.union($1.1) }
            for released in required {
                var router = WindowSwitchKeyRouter(hotkey: .init(keyCode: 49, modifiers: carbon))
                XCTAssertEqual(router.key(code: 49, down: true, flags: flags.union(.maskShift)).action, .begin(backwards: true))
                XCTAssertNil(router.modifiers(flags: flags).action)
                XCTAssertEqual(router.key(code: 49, down: true, flags: flags).action, .step(backwards: false))
                XCTAssertEqual(router.modifiers(flags: flags.subtracting(released.1)).action, .commit)
                XCTAssertNil(router.modifiers(flags: []).action)
            }
        }
    }

    func testOptionTabEscapeAndTypingRetirePendingSelectionAndActivation() throws {
        let messages = ShortcutMessages()
        let input = WindowSwitchInput(hotkey: .init(keyCode: 48, modifiers: UInt32(optionKey))) { messages.append($0) }
        _ = input.receive(type: .keyDown, event: try event(48, flags: .maskAlternate))
        XCTAssertTrue(input.receive(type: .keyDown, event: try event(53, flags: .maskAlternate)) == nil)
        _ = input.receive(type: .flagsChanged, event: try event(58))
        XCTAssertEqual(messages.actions, [.begin(backwards: false), .cancel])
        _ = input.receive(type: .keyUp, event: try event(48, down: false))
        _ = input.receive(type: .keyDown, event: try event(48, flags: .maskAlternate))
        let session = try XCTUnwrap(input.state.sessionID)
        _ = input.receive(type: .flagsChanged, event: try event(58))
        let activation = UUID()
        XCTAssertTrue(input.finish(session: session, activating: activation))
        _ = input.receive(type: .keyDown, event: try event(0))
        XCTAssertFalse(input.isActivationPending(activation), "A custom shortcut must retain immediate cancellation across the AX boundary")
    }

    func testLegacyPreferencesStillRouteCommandTab() throws {
        let legacy = Data(#"{"historyEnabled":false,"historyLimit":200,"historyRetentionDays":30}"#.utf8)
        let preferences = try JSONDecoder().decode(Preferences.self, from: legacy)
        let hotkey = preferences.toolkitSettings.effectiveWindowSwitcherHotkey
        XCTAssertEqual(hotkey, WindowSwitchKeyRouter.defaultHotkey)
        let messages = ShortcutMessages()
        let input = WindowSwitchInput(hotkey: hotkey) { messages.append($0) }
        XCTAssertTrue(input.receive(type: .keyDown, event: try event(48, flags: .maskCommand)) == nil)
        _ = input.receive(type: .flagsChanged, event: try event(55))
        XCTAssertEqual(messages.actions, [.begin(backwards: false), .commit])
    }

    @MainActor
    func testSwitcherValidationReservesShiftAndNavigationKeys() {
        for key in [Hotkey(keyCode: 48, modifiers: UInt32(optionKey)), .init(keyCode: 49, modifiers: UInt32(controlKey)),
                    .init(keyCode: 3, modifiers: UInt32(cmdKey | optionKey | controlKey))] {
            XCTAssertNil(HotkeyManager.validationError(key, purpose: .windowSwitcher))
        }
        XCTAssertNotNil(HotkeyManager.validationError(.init(keyCode: 48, modifiers: UInt32(cmdKey | shiftKey)), purpose: .windowSwitcher))
        for code: UInt32 in [36, 51, 53, 76, 123, 124, 125, 126] {
            XCTAssertNotNil(HotkeyManager.validationError(.init(keyCode: code, modifiers: UInt32(optionKey)), purpose: .windowSwitcher))
        }
        XCTAssertNotNil(HotkeyManager.validationError(.init(keyCode: 48, modifiers: 0), purpose: .windowSwitcher))
        XCTAssertNotNil(HotkeyManager.validationError(.init(keyCode: 8, modifiers: UInt32(cmdKey)), purpose: .windowSwitcher))
    }

    private func event(_ code: CGKeyCode, down: Bool = true, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        event.flags = flags
        return event
    }
}

private final class ShortcutMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WindowSwitchInput.Event] = []
    func append(_ event: WindowSwitchInput.Event) { lock.withLock { values.append(event) } }
    var actions: [WindowSwitchKeyRouter.Action] {
        lock.withLock { values.compactMap { if case .key(let result, _) = $0 { return result.action }; return nil } }
    }
}
