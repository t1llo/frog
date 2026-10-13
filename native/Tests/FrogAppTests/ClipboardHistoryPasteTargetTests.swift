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
