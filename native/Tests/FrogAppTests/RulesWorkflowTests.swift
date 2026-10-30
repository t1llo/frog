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
        // The app starts its plugins at launch; their pages exist only once they run.
        await model.pluginHost.syncAndWait()
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
        if audio {
            try await click("Dictation", in: host)
            XCTAssertEqual(model.toolkit.route, .feature(.dictation), "The Dictation sidebar item must open its page")
            // A dictation rule is a section of the page: New rule adds one there, with no editor to fill in first.
            try await click("New rule", in: host)
            XCTAssertNil(window.attachedSheet)
            let saved = try XCTUnwrap(store.load().rules.first, "The new rule must be persisted")
            XCTAssertEqual(saved.name, "Dictation")
            XCTAssertEqual(saved.category, .audio)
            XCTAssertEqual(model.configuration.rules.count, 1)
            let section = try await AccessibleControls.element("Enable Dictation", in: host)
            XCTAssertNotNil(section, "The page must show the new rule's section")
            return
        }
        XCTAssertEqual(model.toolkit.route, .feature(.writing), "The window opens on Writing")
        try await click("New rule", in: host)
        let sheet = try XCTUnwrap(window.attachedSheet, "Clicking New rule must open the editor")
        let content = try XCTUnwrap(sheet.contentView)
        let name = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }.first { $0.stringValue == "New text rule" })
        sheet.makeFirstResponder(name)
        let editor = try XCTUnwrap(name.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Created from the UI", replacementRange: NSRange(location: NSNotFound, length: 0))
        sheet.makeFirstResponder(nil)
        try await click("Save", in: content)
        XCTAssertNil(window.attachedSheet, "Saving must dismiss the editor")
        let saved = try XCTUnwrap(store.load().rules.first, "The new rule must be persisted")
        XCTAssertEqual(saved.name, "Created from the UI")
        XCTAssertEqual(saved.category, .text)
        XCTAssertEqual(model.configuration.rules.count, 1)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    /// Clicks the control labelled `label`, after checking that no window-drag area lies over it.
    private func click(_ label: String, in view: NSView) async throws {
        let element = try await AccessibleControls.require(label, in: view)
        let frame = try AccessibleControls.frame(of: element, in: view)
        let target = view.hitTest(view.convert(NSPoint(x: frame.midX, y: frame.midY), to: view.superview))
        XCTAssertFalse(target is WindowDragRegion.DragView, "Window dragging must not cover a control")
        guard !(target is WindowDragRegion.DragView) else { return }
        try await AccessibleControls.click(label, in: view)
    }
}
