import AppKit
import ApplicationServices
import XCTest
@testable import FrogApp

/// The decisions of the paste target against a stand-in for the other application.
/// No panel is shown and no Accessibility message leaves the process.
@MainActor
final class ClipboardHistoryPasteTargetTests: XCTestCase {
    func testOpeningDoesNotWalkTheMenusOfTheOtherApplication() async throws {
        // A terminal-style field: a text role, no insertion range, no editable value.
        let probe = TargetProbe()
        probe.pasteMenu = true
        let target = try XCTUnwrap(NativeClipboardHistoryPasteTarget.capture(pid: probe.pid, access: probe.access))
        XCTAssertEqual(probe.menuWalks, 0, "Looking for the Paste command reads the whole menu bar; it waits until an item is chosen")
        XCTAssertEqual(probe.editableReads, 0)
        try await target.prepareForPaste(isCurrent: { true })
        try target.paste()
        XCTAssertEqual(probe.commands, 1)
        XCTAssertGreaterThan(probe.menuWalks, 0, "The Paste command is still required before pasting")
    }

    func testFieldWithoutAnyWayToPasteStaysCopyOnly() async throws {
        let probe = TargetProbe()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let target = NativeClipboardHistoryPasteTarget.capture(pid: probe.pid, access: probe.access)
        XCTAssertEqual(probe.menuWalks, 0)
        do {
            try await ClipboardHistoryDelivery.paste(ClipboardHistoryEntry(text: "chosen"), plainText: true, pasteboard: pasteboard,
                                                     target: target, isCurrent: { true }, waitForRelease: {})
            XCTFail("Nothing may be pasted into a field that takes no Paste")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("The item is copied"), error.localizedDescription)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "chosen")
        XCTAssertEqual(probe.commands, 0)
    }

    func testEditabilityIsAskedOnceAndStillDecidesForOtherRoles() {
        let probe = TargetProbe()
        probe.role = "AXWebArea"; probe.editable = true
        XCTAssertNotNil(NativeClipboardHistoryPasteTarget.capture(pid: probe.pid, access: probe.access))
        XCTAssertEqual(probe.editableReads, 1)
        XCTAssertEqual(probe.menuWalks, 0)

        // A page that is only read never becomes a target, whatever the menu bar offers.
        probe.editable = false; probe.pasteMenu = true
        XCTAssertNil(NativeClipboardHistoryPasteTarget.capture(pid: probe.pid, access: probe.access))
        XCTAssertEqual(probe.menuWalks, 0)
    }

    func testWindowAndFieldOfTheOtherApplicationGetATimeLimitOfTheirOwn() {
        let application = AXUIElementCreateApplication(900_100)
        let window = AXUIElementCreateApplication(900_101), field = AXUIElementCreateApplication(900_102)
        var steps: [String] = []
        let name: (AXUIElement) -> String = { CFEqual($0, window) ? "window" : CFEqual($0, field) ? "field" : "other" }
        let access = ClipboardHistoryTargetAccess.live(application: application, pid: 900_100,
            element: { asked, attribute in
                guard CFEqual(asked, application) else { return nil }
                return attribute == kAXFocusedWindowAttribute ? window : attribute == kAXFocusedUIElementAttribute ? field : nil
            },
            limit: { steps.append("\(name($0)) \($1)") },
            focus: { steps.append("focus \(name($0))") })
        XCTAssertEqual(access.window().map(name), "window")
        XCTAssertEqual(access.focused().map(name), "field")
        // The application's own limit does not reach what it hands out.
        XCTAssertEqual(steps, ["window 0.15", "field 0.15"])

        // Handing focus back is a request, not a question: it keeps the time it always had.
        steps = []
        access.restoreFocus(field)
        XCTAssertEqual(steps, ["field 0.0", "focus field", "field 0.15"])
    }

    func testCopyOnlyMessageNamesAccessibilityOnlyWhenItIsMissing() async {
        let granted = ClipboardHistoryDelivery.copyOnlyMessage(trusted: true, frontmostPID: 7, ownPID: 9)
        XCTAssertFalse(granted.contains("Accessibility"), granted)
        let missing = ClipboardHistoryDelivery.copyOnlyMessage(trusted: false, frontmostPID: 7, ownPID: 9)
        XCTAssertTrue(missing.contains("Accessibility"), missing)
        // A field in one of Frog's own windows: the permission has nothing to do with it.
        let own = [true, false].map { ClipboardHistoryDelivery.copyOnlyMessage(trusted: $0, frontmostPID: 9, ownPID: 9) }
        for message in own {
            XCTAssertFalse(message.contains("Accessibility"), message)
            XCTAssertTrue(message.contains("its own windows"), message)
        }

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        do {
            try await ClipboardHistoryDelivery.paste(ClipboardHistoryEntry(text: "chosen"), plainText: true, pasteboard: pasteboard,
                                                     target: nil, isCurrent: { true }, waitForRelease: {})
            XCTFail("Without a field there is nothing to paste into")
        } catch {
            XCTAssertTrue(([granted, missing] + own).contains(error.localizedDescription), error.localizedDescription)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "chosen")
    }
}

@MainActor private final class TargetProbe {
    // Stand-ins that are only compared, never asked anything.
    let window = AXUIElementCreateApplication(900_101)
    let field = AXUIElementCreateApplication(900_102)
    let pid: pid_t = 900_100
    var role = kAXTextAreaRole as String
    var range: CFRange?
    var editable = false
    var pasteMenu = false
    var editableReads = 0
    var menuWalks = 0
    var commands = 0

    var access: ClipboardHistoryTargetAccess {
        ClipboardHistoryTargetAccess(trusted: { true }, frontmostPID: { self.pid }, ownPID: -1,
            window: { self.window }, focused: { self.field },
            range: { _ in self.range }, role: { _ in self.role }, secure: { _ in false }, enabled: { _ in true },
            editable: { _ in self.editableReads += 1; return self.editable },
            nativePasteAvailable: { self.menuWalks += 1; return self.pasteMenu },
            pause: {}, command: { self.commands += 1 })
    }
}
