import AppKit
import SwiftUI
import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class RuleEditorTests: XCTestCase {
    func testModelPickerInsideSheetAfterDeletingSelectedDownload() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for id in ["whisper-base", "parakeet-v3"] {
            let folder = directory.appendingPathComponent("Models/\(id)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("fixture"), withIntermediateDirectories: true)
            try "fixture".write(to: folder.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
        }
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "whisper-base"
        var configuration = Configuration()
        let provider = ProviderConfiguration(model: "remote-speech", models: [.init(id: "remote-speech", category: .audio), .init(id: "text-one"), .init(id: "text-two")])
        configuration.providers = [provider]
        configuration.rules = [rule]; configuration.explicitRuleModels = true
        try ConfigurationStore(directory: directory).save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        var presented = false
        let host = NSHostingView(rootView: Color.clear.frame(width: 720, height: 600)
            .sheet(isPresented: Binding(get: { presented }, set: { presented = $0 })) { RuleEditor(rule: rule).environmentObject(model) })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        presented = true
        host.rootView = Color.clear.frame(width: 720, height: 600)
            .sheet(isPresented: Binding(get: { presented }, set: { presented = $0 })) { RuleEditor(rule: rule).environmentObject(model) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(window.attachedSheet)
        try await model.deleteLocalModel(try XCTUnwrap(LocalModelDescriptor.find("whisper-base")))
        try await Task.sleep(for: .milliseconds(100))
        // One list holds both kinds: first an external provider's speech model, then a downloaded one.
        let parakeet = try XCTUnwrap(LocalModelDescriptor.find("parakeet-v3")).name
        for local in [false, true] {
            let sheet = try XCTUnwrap(window.attachedSheet)
            let content = try XCTUnwrap(sheet.contentView)
            try await AccessibleControls.click("Speech model", role: .button, in: content)
            let popup = try XCTUnwrap(NSApplication.shared.windows.first { $0 != window && $0 != sheet && $0.isVisible })
            let search = try XCTUnwrap(popup.firstResponder as? NSTextView, "The list opens with the cursor in its search field")
            search.insertText(local ? parakeet : "remote-speech", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(100))
            try await press(popup, key: 36, characters: "\r")
            XCTAssertFalse(popup.isVisible, "The picker must still offer a selectable model")
            try await AccessibleControls.click("Save", in: content)
            XCTAssertEqual(model.configuration.rules[0].action?.audioModelID, local ? "parakeet-v3" : "remote-speech")
            XCTAssertEqual(model.configuration.rules[0].action?.audioProviderID, local ? nil : provider.id)
            if !local {
                rule = model.configuration.rules[0]
                presented = true
                host.rootView = Color.clear.frame(width: 720, height: 600)
                    .sheet(isPresented: Binding(get: { presented }, set: { presented = $0 })) { RuleEditor(rule: rule).environmentObject(model) }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        XCTAssertTrue(model.localModels.loaded.isEmpty)
    }

    func testSavingAnOpenAudioEditorDoesNotRestoreADeletedModel() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for id in ["whisper-base", "whisper-tiny", "qwen-0.6b"] {
            let folder = directory.appendingPathComponent("Models/\(id)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("fixture"), withIntermediateDirectories: true)
            try "fixture".write(to: folder.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
        }
        var rule = Rule.dictationPreset
        rule.name = "Audio draft"; rule.action?.audioModelID = "whisper-base"
        rule.action?.localTextModelID = "qwen-0.6b"; rule.action?.cleanup = true
        var configuration = Configuration()
        configuration.rules = [rule]; configuration.explicitRuleModels = true
        let store = ConfigurationStore(directory: directory)
        try store.save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        let host = NSHostingView(rootView: RuleEditor(rule: rule).environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 520, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let name = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.stringValue == rule.name })
        window.makeFirstResponder(name)
        let editor = try XCTUnwrap(name.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Unsaved edit", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.makeFirstResponder(nil)
        try await model.deleteLocalModel(try XCTUnwrap(LocalModelDescriptor.find("whisper-base")))
        XCTAssertEqual(model.configuration.rules[0].action?.audioModelID, "whisper-tiny")
        try await Task.sleep(for: .milliseconds(100))
        let point = host.convert(NSPoint(x: 472, y: host.isFlipped ? 431 : 29), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
        let saved = try XCTUnwrap(store.load().rules.first)
        XCTAssertEqual(saved.name, "Unsaved edit", "The editor must save its draft, including unrelated edits")
        XCTAssertEqual(saved.action?.audioModelID, "whisper-tiny", "Saving an existing draft must not restore the deleted download")
        XCTAssertEqual(saved.action?.localTextModelID, "qwen-0.6b")
        XCTAssertTrue(model.localModels.loaded.isEmpty)
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
