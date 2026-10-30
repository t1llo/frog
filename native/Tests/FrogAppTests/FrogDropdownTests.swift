import AppKit
import SwiftUI
import XCTest
@testable import FrogApp

final class FrogDropdownTests: XCTestCase {
    func testArrowsStepOverNothingAndWrapAround() {
        let navigation = FrogDropdownNavigation(values: ["a", "b", "c"])
        XCTAssertEqual(navigation.next(after: nil, by: 1), "a", "Down from nothing starts at the top")
        XCTAssertEqual(navigation.next(after: nil, by: -1), "c", "Up from nothing starts at the bottom")
        XCTAssertEqual(navigation.next(after: "a", by: 1), "b")
        XCTAssertEqual(navigation.next(after: "c", by: 1), "a")
        XCTAssertEqual(navigation.next(after: "a", by: -1), "c")
        XCTAssertEqual(navigation.next(after: "gone", by: 1), "a", "A highlight the search hid starts over")
        XCTAssertNil(FrogDropdownNavigation<String>(values: []).next(after: nil, by: 1))
    }

    func testSurfacesAreOpaqueUntilTransparencyIsAskedFor() {
        XCTAssertEqual(FrogSurfaceRendering.choose(.hud, amount: 0, glassAvailable: true), .opaque)
        XCTAssertEqual(FrogSurfaceRendering.choose(.hud, amount: 0.4, glassAvailable: true), .glass)
        XCTAssertEqual(FrogSurfaceRendering.choose(.hud, amount: 0.4, glassAvailable: false), .material)
        XCTAssertEqual(FrogSurfaceRendering.choose(.popover, amount: 0.4, glassAvailable: true), .tint, "A popover brings its own glass")
        XCTAssertEqual(FrogSurfaceRendering.choose(.window, amount: 0.4, glassAvailable: true), .material, "Glass is for chrome, not content")
    }

    /// Without a search field the list takes the keys: it opens on the chosen row, Down moves, Return chooses,
    /// and Escape closes without choosing.
    @MainActor
    func testTheKeyboardDrivesAPlainList() async throws {
        _ = NSApplication.shared
        final class Box { var value = "Nord" }
        let box = Box()
        let host = NSHostingView(rootView: FrogDropdown(selection: Binding(get: { box.value }, set: { box.value = $0 }),
                                                        options: ["Frog", "Nord", "Dracula"], title: { $0 }).padding(40))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await click(host, at: NSPoint(x: host.bounds.midX, y: host.bounds.midY))
        var popup = try XCTUnwrap(NSApplication.shared.windows.first { $0 != window && $0.isVisible })
        try await press(popup, key: 53, characters: "\u{1b}")
        XCTAssertEqual(box.value, "Nord")
        XCTAssertFalse(popup.isVisible, "Escape closes the list")
        try await click(host, at: NSPoint(x: host.bounds.midX, y: host.bounds.midY))
        popup = try XCTUnwrap(NSApplication.shared.windows.first { $0 != window && $0.isVisible })
        try await press(popup, key: 125, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        try await press(popup, key: 36, characters: "\r")
        XCTAssertEqual(box.value, "Dracula")
    }

    @MainActor
    private func click(_ view: NSView, at point: NSPoint) async throws {
        let window = try XCTUnwrap(view.window)
        let point = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        try await Task.sleep(for: .milliseconds(200))
    }

    @MainActor
    private func press(_ window: NSWindow, key: UInt16, characters: String) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key)))
        }
        try await Task.sleep(for: .milliseconds(200))
    }
}
