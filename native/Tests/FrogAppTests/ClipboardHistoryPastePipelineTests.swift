import AppKit
import ApplicationServices
import FrogCore
import XCTest
@testable import FrogApp

@MainActor
final class ClipboardHistoryPastePipelineTests: XCTestCase {
    func testOriginalNativeEditorReceivesPasteAfterPopup() async throws {
        try await exerciseNativeEditor(exposesRange: true)
    }

    func testOriginalNativeEditorWithoutAXRangeReceivesPasteAfterPopup() async throws {
        try await exerciseNativeEditor(exposesRange: false)
    }

    func testExplicitlyEditableWebAreaReceivesPaste() async throws {
        try await exerciseNativeEditor(exposesRange: false, configure: { $0.roleOverride = "AXWebArea" })
    }

    func testReadOnlyWebAreaNeverReceivesPasteEvenWithAppPasteMenu() async throws {
        try await exerciseNativeEditor(exposesRange: false, expectedPaste: false, configure: {
            $0.roleOverride = "AXWebArea"; $0.axEditable = false; $0.nativePasteAvailable = true
        })
    }

    func testTerminalStyleReadOnlyAXTextAreaWithNativePasteReceivesPaste() async throws {
        try await exerciseNativeEditor(exposesRange: false, configure: {
            $0.axEditable = false; $0.nativePasteAvailable = true
        })
    }

    func testXtermStyleSeparateOutputChangesKeepOriginalInputCaretValid() async throws {
        // Observed in an isolated VS Code terminal: the focused helper textarea
        // stays empty with range 0...0 while a separate accessible output tree
        // grows. Keep range validation rather than exempting terminal apps.
        let output = "Synthetic background output 1\nSynthetic background output 2"
        try await exerciseNativeEditor(exposesRange: true, expectedEditorText: "chosen fixture",
            expectedOtherText: output, configure: {
                $0.editor.string = ""
                $0.editor.setSelectedRange(NSRange(location: 0, length: 0))
                $0.nativePasteAvailable = true
            }, whilePresented: { $0.other.string = output })
    }

    func testReadOnlyTextWithoutPasteCapabilityStaysCopyOnly() async throws {
        try await exerciseNativeEditor(exposesRange: false, expectedPaste: false, configure: { $0.axEditable = false })
    }

    func testOriginalFieldIsRestoredAfterPopupFocusHandoff() async throws {
        try await exerciseNativeEditor(exposesRange: false, afterClose: {
            $0.window.makeFirstResponder(nil)
        })
    }

    func testDifferentFieldAfterPopupIsNeverRestoredOrPastedInto() async throws {
        try await exerciseNativeEditor(exposesRange: false, expectedPaste: false, afterClose: {
            $0.window.makeFirstResponder($0.other)
        })
    }

    func testChangedApplicationNeverReceivesPaste() async throws {
        try await exerciseNativeEditor(exposesRange: false, expectedPaste: false, afterClose: { $0.frontmostPID += 1 })
    }

    func testChangedWindowNeverReceivesPaste() async throws {
        try await exerciseNativeEditor(exposesRange: false, expectedPaste: false, afterClose: { $0.changedWindow = true })
    }

    func testChangedSelectionRemainsProtectedWhenRangeIsAvailable() async throws {
        try await exerciseNativeEditor(exposesRange: true, expectedPaste: false, afterClose: {
            $0.editor.setSelectedRange(NSRange(location: 0, length: 0))
        })
    }

    func testSecureAndDisabledFieldsStayCopyOnly() async throws {
        try await exerciseNativeEditor(exposesRange: false, expectedPaste: false, configure: { $0.secure = true })
        try await exerciseNativeEditor(exposesRange: false, expectedPaste: false, afterClose: { $0.secure = true })
        try await exerciseNativeEditor(exposesRange: false, expectedPaste: false, afterClose: { $0.editor.isEditable = false })
    }

    func testRichPlainAndSensitiveDeliveryIntoOriginalNativeField() async throws {
        for plain in [false, true] {
            try await exerciseNativeEditor(exposesRange: false, plain: plain, richSensitive: true)
        }
    }

    func testFocusRestorationWaitIsBoundedAndCannotRedirectToAnotherField() async throws {
        try await exerciseNativeEditor(exposesRange: false, expectedPaste: false, configure: {
            $0.restoresKeyboardFocus = false
            $0.pause = { await Task.yield() }
        })
        try await exerciseNativeEditor(exposesRange: false, expectedPaste: false, configure: { fixture in
            fixture.pause = { fixture.window.makeFirstResponder(fixture.other) }
        })
    }

    func testClearDisableCancelAndInputDuringFocusHandoffPreventClipboardWriteAndPaste() async throws {
        for action in ["clear", "disable", "cancel", "input"] {
            let fixture = ClipboardEditorFixture(exposesRange: false)
            defer { fixture.close() }
            let history = ClipboardHistoryStore(pasteboard: fixture.pasteboard)
            history.configure(enabled: true, automaticallyPoll: false)
            history.recordCopiedText("chosen fixture")
            fixture.pasteboard.setString("unchanged fixture clipboard", forType: .string)
            let controller = ClipboardHistoryController(pasteboard: fixture.pasteboard, history: history,
                captureTarget: { NativeClipboardHistoryPasteTarget.capture(pid: fixture.pid, access: fixture.access) },
                waitForRelease: {}, activationNotifications: NotificationCenter())
            defer { controller.stop() }
            var errors: [String] = []
            controller.onError = { errors.append($0.localizedDescription) }
            fixture.pause = {
                switch action {
                case "clear": history.clear()
                case "disable": controller.configure(enabled: false)
                case "cancel": controller.cancel()
                default:
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                        context: nil, characters: "\u{f702}", charactersIgnoringModifiers: "\u{f702}", isARepeat: false, keyCode: 123)!
                    NSApp.sendEvent(event)
                }
            }
            fixture.show(); controller.show()
            let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "Clipboard history" })
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            NSApp.sendEvent(enter)
            await controller.waitForDelivery()
            XCTAssertEqual(fixture.editor.string, "before replace after", action)
            XCTAssertEqual(fixture.other.string, "unrelated field", action)
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), "unchanged fixture clipboard", action)
            XCTAssertTrue(errors.isEmpty, action)
        }
    }

    private func exerciseNativeEditor(exposesRange: Bool, expectedPaste: Bool = true,
                                      plain: Bool = false, richSensitive: Bool = false,
                                      expectedEditorText: String? = nil, expectedOtherText: String = "unrelated field",
                                      configure: (ClipboardEditorFixture) -> Void = { _ in },
                                      whilePresented: (ClipboardEditorFixture) -> Void = { _ in },
                                      afterClose: @escaping (ClipboardEditorFixture) -> Void = { _ in }) async throws {
        _ = NSApplication.shared
        let fixture = ClipboardEditorFixture(exposesRange: exposesRange)
        defer { fixture.close() }
        configure(fixture)
        let history = ClipboardHistoryStore(pasteboard: fixture.pasteboard)
        history.configure(enabled: true, automaticallyPoll: false)
        let rich = NSAttributedString(string: "chosen fixture", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let entry = ClipboardHistoryEntry(text: "chosen fixture", formatting: richSensitive ? [NSPasteboard.PasteboardType.rtf.rawValue: rtf] : [:], isSensitive: richSensitive)
        XCTAssertTrue(entry.write(to: fixture.pasteboard, plainText: false))
        await history.poll()
        let controller = ClipboardHistoryController(pasteboard: fixture.pasteboard, history: history,
            captureTarget: { NativeClipboardHistoryPasteTarget.capture(pid: fixture.pid, access: fixture.access) },
            waitForRelease: { afterClose(fixture) }, activationNotifications: NotificationCenter())
        defer { controller.stop() }
        var errors: [String] = []
        controller.onError = { errors.append($0.localizedDescription) }
        fixture.show()
        controller.show()
        try await Task.sleep(for: .milliseconds(50))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "Clipboard history" })
        panel.contentView?.layoutSubtreeIfNeeded()
        // Exercise actual popup search focus, then select using its real event monitor.
        let search = try XCTUnwrap(descendants(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSTextField }.first)
        panel.makeFirstResponder(search)
        controller.state.revealedIDs = Set(history.entries.map(\.id))
        controller.state.query = "chosen"
        whilePresented(fixture)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: plain ? .shift : [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        NSApp.sendEvent(enter)
        await controller.waitForDelivery()
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(fixture.editor.string, expectedEditorText ?? (expectedPaste ? "before chosen fixture after" : "before replace after"), errors.joined(separator: "; "))
        XCTAssertEqual(fixture.other.string, expectedOtherText)
        XCTAssertEqual(errors.isEmpty, expectedPaste, errors.joined(separator: "; "))
        if richSensitive {
            XCTAssertTrue(fixture.pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
            let font = fixture.editor.textStorage?.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
            XCTAssertEqual(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false, !plain)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

/// Real AppKit fields and first-responder routing; only cross-process AX transport
/// is replaced. Neither the general pasteboard nor another application's UI is used.
@MainActor
private final class ClipboardEditorFixture {
    let pasteboard = NSPasteboard.withUniqueName()
    let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 400, height: 180),
                         styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    let editor = ClipboardFixtureTextView(frame: NSRect(x: 0, y: 80, width: 400, height: 100))
    let other = ClipboardFixtureTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
    let pid: pid_t = 900_001
    let windowID = AXUIElementCreateApplication(900_002)
    let editorID = AXUIElementCreateApplication(900_003)
    let otherID = AXUIElementCreateApplication(900_004)
    let exposesRange: Bool
    var roleOverride: String?
    var axEditable = true
    var nativePasteAvailable = false
    var secure = false
    var frontmostPID: pid_t = 900_001
    var changedWindow = false
    var restoresKeyboardFocus = true
    var pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) }

    init(exposesRange: Bool) {
        self.exposesRange = exposesRange
        editor.fixturePasteboard = pasteboard; other.fixturePasteboard = pasteboard
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        window.contentView?.addSubview(editor); window.contentView?.addSubview(other)
        editor.string = "before replace after"
        editor.setSelectedRange(NSRange(location: 7, length: 7))
        other.string = "unrelated field"
    }

    func show() { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor) }
    func close() { pause = {}; window.orderOut(nil); pasteboard.releaseGlobally() }

    var access: ClipboardHistoryTargetAccess {
        ClipboardHistoryTargetAccess(trusted: { true }, frontmostPID: { self.frontmostPID }, ownPID: -1,
            window: { self.window.isVisible ? (self.changedWindow ? self.otherID : self.windowID) : nil },
            focused: {
                if self.window.firstResponder === self.editor { return self.editorID }
                if self.window.firstResponder === self.other { return self.otherID }
                return nil
            },
            range: { element in
                guard self.exposesRange else { return nil }
                let range = self.view(element).accessibilitySelectedTextRange()
                return CFRange(location: range.location, length: range.length)
            }, role: { self.roleOverride ?? self.view($0).accessibilityRole()?.rawValue }, secure: { _ in self.secure },
            enabled: { self.view($0).isEditable }, editable: { self.axEditable && self.view($0).isEditable },
            nativePasteAvailable: { self.nativePasteAvailable },
            keyboardFocused: { self.window.isKeyWindow && self.window.firstResponder === self.view($0) },
            restoreFocus: { element in
                guard self.restoresKeyboardFocus else { return }
                self.window.makeKeyAndOrderFront(nil)
                self.window.makeFirstResponder(self.view(element))
            },
            pause: { try await self.pause() },
            command: {
                // Route the real Paste selector through AppKit's responder chain,
                // not directly to the retained editor. A wrong key window/field
                // will therefore fail the text assertions above.
                XCTAssertTrue(NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil))
            })
    }

    private func view(_ element: AXUIElement) -> NSTextView { CFEqual(element, editorID) ? editor : other }
}

@MainActor
private final class ClipboardFixtureTextView: NSTextView {
    var fixturePasteboard: NSPasteboard?
    override func paste(_ sender: Any?) {
        guard let fixturePasteboard else { return }
        XCTAssertTrue(readSelection(from: fixturePasteboard))
    }
}
