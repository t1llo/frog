import AppKit
import SwiftUI
import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class RulesWorkflowTests: XCTestCase {
    func testCreateTextRuleFromMainWindow() async throws {
        try await createRule(audio: false)
    }

    func testCreateAudioRuleFromMainWindow() async throws {
        try await createRule(audio: true)
    }

    private func createRule(audio: Bool) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(directory: directory)
        var configuration = Configuration()
        configuration.rules = []; configuration.explicitRuleModels = true
        try store.save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        let host = NSHostingView(rootView: MainView().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 800, height: 580),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = host; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified; window.backgroundColor = .clear; window.isOpaque = false
        window.setContentSize(NSSize(width: 800, height: 580))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        if audio { try await click(host, x: 268, top: 114) }
        try await click(host, x: host.bounds.maxX - 100, top: 80)
        let sheet = try XCTUnwrap(window.attachedSheet, "Clicking New rule must open the editor")
        let content = try XCTUnwrap(sheet.contentView)
        let name = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }.first {
            $0.stringValue == (audio ? "New audio rule" : "New text rule")
        })
        sheet.makeFirstResponder(name)
        let editor = try XCTUnwrap(name.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Created from the UI", replacementRange: NSRange(location: NSNotFound, length: 0))
        sheet.makeFirstResponder(nil)
        try await click(content, x: content.bounds.maxX - 48, top: content.bounds.height - 29)
        XCTAssertNil(window.attachedSheet, "Saving must dismiss the editor")
        let saved = try XCTUnwrap(store.load().rules.first, "The new rule must be persisted")
        XCTAssertEqual(saved.name, "Created from the UI")
        XCTAssertEqual(saved.category, audio ? .audio : .text)
        XCTAssertEqual(model.configuration.rules.count, 1)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func click(_ view: NSView, x: CGFloat, top: CGFloat) async throws {
        let window = try XCTUnwrap(view.window)
        let location = NSPoint(x: x, y: view.isFlipped ? top : view.bounds.height - top)
        let target = view.hitTest(view.convert(location, to: view.superview))
        XCTAssertFalse(target is WindowDragRegion.DragView, "Window dragging must not cover a control")
        guard !(target is WindowDragRegion.DragView) else { return }
        let point = view.convert(location, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        try await Task.sleep(for: .milliseconds(150))
    }
}
