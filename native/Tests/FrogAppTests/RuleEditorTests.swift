import AppKit
import SwiftUI
import XCTest
import FrogCore
@testable import FrogApp

/// Choosing and keeping a rule's model while its download is deleted: on the Dictation page, which saves each
/// change, and in the Writing editor, which saves a draft.
@MainActor
final class RuleEditorTests: XCTestCase {
    func testDictationModelPickerAfterDeletingTheSelectedDownload() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try install(["whisper-base", "parakeet-v3"], in: directory)
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "whisper-base"
        var configuration = Configuration()
        let provider = ProviderConfiguration(model: "remote-speech", models: [.init(id: "remote-speech", category: .audio), .init(id: "text-one"), .init(id: "text-two")])
        configuration.providers = [provider]
        configuration.rules = [rule]; configuration.explicitRuleModels = true
        let store = ConfigurationStore(directory: directory)
        try store.save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        await model.pluginHost.syncAndWait()
        let host = NSHostingView(rootView: try XCTUnwrap(model.pluginHost.page(for: "dictation")))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await model.deleteLocalModel(try XCTUnwrap(LocalModelDescriptor.find("whisper-base")))
        try await Task.sleep(for: .milliseconds(100))
        // One list holds both kinds: first an external provider's speech model, then a downloaded one.
        let parakeet = try XCTUnwrap(LocalModelDescriptor.find("parakeet-v3")).name
        for local in [false, true] {
            try await AccessibleControls.click("Speech model", role: .button, in: host)
            let popup = try XCTUnwrap(NSApplication.shared.windows.first { $0 != window && $0.isVisible })
            let search = try XCTUnwrap(popup.firstResponder as? NSTextView, "The list opens with the cursor in its search field")
            search.insertText(local ? parakeet : "remote-speech", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(100))
            try await press(popup, key: 36, characters: "\r")
            XCTAssertFalse(popup.isVisible, "The picker must still offer a selectable model")
            let saved = try XCTUnwrap(store.load().rules.first)
            XCTAssertEqual(saved.action?.audioModelID, local ? "parakeet-v3" : "remote-speech")
            XCTAssertEqual(saved.action?.audioProviderID, local ? nil : provider.id)
        }
        XCTAssertTrue(model.localModels.loaded.isEmpty, "Choosing a model does not load it")
    }

    func testSavingAnOpenWritingEditorDoesNotRestoreADeletedModel() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try install(["qwen-0.6b", "qwen-1.7b"], in: directory)
        var rule = Rule()
        rule.name = "Text draft"; rule.action = RuleAction(category: .text); rule.action?.localTextModelID = "qwen-0.6b"
        var configuration = Configuration()
        configuration.rules = [rule]; configuration.explicitRuleModels = true
        let store = ConfigurationStore(directory: directory)
        try store.save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        var presented = true
        let host = NSHostingView(rootView: Color.clear.frame(width: 720, height: 700)
            .sheet(isPresented: Binding(get: { presented }, set: { presented = $0 })) { WritingRuleEditor(rule: rule) { _ in }.environmentObject(model) })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        let name = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }.first { $0.stringValue == rule.name })
        sheet.makeFirstResponder(name)
        let editor = try XCTUnwrap(name.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Unsaved edit", replacementRange: NSRange(location: NSNotFound, length: 0))
        sheet.makeFirstResponder(nil)
        try await model.deleteLocalModel(try XCTUnwrap(LocalModelDescriptor.find("qwen-0.6b")))
        let replacement = model.configuration.rules[0].action?.localTextModelID
        XCTAssertNotEqual(replacement, "qwen-0.6b")
        try await Task.sleep(for: .milliseconds(100))
        try await AccessibleControls.click("Save", in: content)
        XCTAssertFalse(presented, "Saving must dismiss the editor")
        let saved = try XCTUnwrap(store.load().rules.first)
        XCTAssertEqual(saved.name, "Unsaved edit", "The editor must save its draft, including unrelated edits")
        XCTAssertEqual(saved.action?.localTextModelID, replacement, "Saving an open draft must not restore the deleted download")
        XCTAssertTrue(model.localModels.loaded.isEmpty)
    }

    /// Marks downloads as installed with a fixture file, without any model data.
    private func install(_ ids: [String], in directory: URL) throws {
        for id in ids {
            let folder = directory.appendingPathComponent("Models/\(id)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("fixture"), withIntermediateDirectories: true)
            try "fixture".write(to: folder.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func press(_ window: NSWindow, key: UInt16, characters: String) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key)))
        }
        try await Task.sleep(for: .milliseconds(150))
    }
}
