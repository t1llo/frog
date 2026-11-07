import AppKit
import SwiftUI
import XCTest
@testable import FrogApp

@MainActor
final class StayAwakeCustomDurationTests: XCTestCase {
    /// The field under the duration list keeps Return for itself: the list must not choose its highlighted row instead.
    func testReturnInTheCustomFieldChoosesTheTypedLength() async throws {
        _ = NSApplication.shared
        var chosen: [Int] = []
        var rows: [StayAwakeController.DurationChoice] = []
        let list = FrogDropdownList(sections: [.init(values: StayAwakePage.durationOptions(.hour))], selected: StayAwakeController.DurationChoice.hour,
                                    item: { FrogDropdownItem($0.title) },
                                    accessory: AnyView(StayAwakeCustomDuration(current: 90) { chosen.append($0) }),
                                    width: 240, choose: { rows.append($0) })
        let host = NSHostingView(rootView: list)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let field = try XCTUnwrap(all(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("4a5", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(field.stringValue, "45", "Only digits are kept")
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(chosen, [45])
        XCTAssertEqual(rows, [], "Return in the field leaves the list's rows alone")
    }
}
