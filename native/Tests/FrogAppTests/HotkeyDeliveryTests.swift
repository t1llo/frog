import AppKit
import Carbon
import FrogCore
import XCTest
@testable import FrogApp

@MainActor
final class HotkeyDeliveryTests: XCTestCase {
    func testUnpairedReleaseCannotInvokeWritingWhenCopyKeyIsReleased() async throws {
        _ = NSApplication.shared
        let manager = HotkeyManager()
        defer { manager.unregister() }
        let rule = Rule(hotkey: Hotkey(keyCode: 8, modifiers: UInt32(optionKey)))
        var presses = 0, triggers = 0
        let issues = manager.register(rules: [rule], onPress: { _ in presses += 1 }) { _ in triggers += 1 }
        // Another running Frog may own Option-C; use an uncommon chord for the
        // handler test if necessary. No key events are posted outside this process.
        if issues[rule.id] != nil {
            var fixture = rule; fixture.hotkey = Hotkey(keyCode: 105, modifiers: UInt32(controlKey | optionKey | shiftKey))
            XCTAssertTrue(manager.register(rules: [fixture], onPress: { _ in presses += 1 }) { _ in triggers += 1 }.isEmpty)
        }
        // Drive the installed Carbon callback with the opaque registration ID,
        // rather than reimplementing or bypassing event dispatch in the test.
        let id = try XCTUnwrap(manager.rulesByID.keys.first)
        try await send(id: id, pressed: false)
        XCTAssertEqual(triggers, 0, "Releasing a key without an accepted Frog press must not start writing")
        try await send(id: id, pressed: true)
        try await send(id: id, pressed: true)
        XCTAssertEqual(presses, 1, "Repeated press notifications must not restart a rule")
        try await send(id: id, pressed: false)
        try await send(id: id, pressed: false)
        XCTAssertEqual(triggers, 1, "Only the matched release may invoke the rule")
    }

    func testRecordingAShortcutSuspendsEveryGroupAndGivesThemBack() {
        _ = NSApplication.shared
        let manager = HotkeyManager()
        defer { manager.unregisterAll() }
        let modifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let frog = Rule(hotkey: Hotkey(keyCode: 105, modifiers: modifiers)), plugin = Rule(hotkey: Hotkey(keyCode: 107, modifiers: modifiers))
        XCTAssertTrue(manager.register(rules: [frog]) { _ in }.isEmpty)
        XCTAssertTrue(manager.register(rules: [plugin], group: "plugin") { _ in }.isEmpty)
        XCTAssertEqual(Set(manager.rulesByID.values), [frog.id, plugin.id])
        manager.setSuspended(true)
        XCTAssertTrue(manager.rulesByID.isEmpty, "No group keeps a key while a shortcut is recorded")
        let late = Rule(hotkey: Hotkey(keyCode: 113, modifiers: modifiers))
        XCTAssertTrue(manager.register(rules: [late], group: "late") { _ in }.isEmpty)
        XCTAssertTrue(manager.rulesByID.isEmpty)
        manager.unregister(group: "plugin")
        manager.setSuspended(false)
        XCTAssertEqual(Set(manager.rulesByID.values), [frog.id, late.id], "A group that let go meanwhile stays gone")
    }

    private func send(id: UInt32, pressed: Bool) async throws {
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(pressed ? kEventHotKeyPressed : kEventHotKeyReleased),
                                   GetCurrentEventTime(), EventAttributes(kEventAttributeUserEvent), &event), noErr)
        let created = try XCTUnwrap(event)
        defer { ReleaseEvent(created) }
        var hotkey = EventHotKeyID(signature: 0x46524F47, id: id)
        XCTAssertEqual(SetEventParameter(created, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        MemoryLayout<EventHotKeyID>.size, &hotkey), noErr)
        XCTAssertEqual(SendEventToEventTarget(created, GetApplicationEventTarget()), noErr)
        try await Task.sleep(for: .milliseconds(10))
    }
}
