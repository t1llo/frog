import AppKit
import SwiftUI
import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class RuleModelPickerTests: XCTestCase {
    func testEmptySelectionOpensDownloadedSpeechChoices() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("Models/whisper-tiny")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("fixture"), withIntermediateDirectories: true)
        try "fixture".write(to: folder.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
        var configuration = Configuration()
        configuration.providers = [ProviderConfiguration(model: "remote-speech", models: [.init(id: "remote-speech", category: .audio)])]
        configuration.explicitRuleModels = true
        try ConfigurationStore(directory: directory).save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = nil
        let host = NSHostingView(rootView: VStack {
            CompactRow(title: "Speech model") {
                RuleModelPicker(rule: Binding(get: { rule }, set: { rule = $0 }), speech: true)
            }
        }.padding(20).frame(width: 520, height: 460).environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 520, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await click(view: host, point: NSPoint(x: host.bounds.maxX - 130, y: host.bounds.midY))
        let popup = try XCTUnwrap(NSApplication.shared.windows.first { $0 != window && $0.isVisible })
        let view = try XCTUnwrap(popup.contentView)
        try await click(view: view, point: NSPoint(x: view.bounds.midX, y: view.isFlipped ? 130 : view.bounds.maxY - 130))
        XCTAssertEqual(rule.action?.audioModelID, "whisper-tiny")
        XCTAssertNil(rule.action?.audioProviderID)
        XCTAssertTrue(model.localModels.loaded.isEmpty)
    }

    func testSwitchingSourceClearsStaleSearchAndShowsLocalModelsWithoutLoadingWeights() async throws {
        try await switchFromExternalToLocal(offset: -55)
    }

    func testSourceSegmentRespondsOutsideItsTextLabel() async throws {
        try await switchFromExternalToLocal(offset: -95)
    }

    private func switchFromExternalToLocal(offset: CGFloat) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let speech = try XCTUnwrap(LocalModelDescriptor.find("whisper-large-v3-turbo-626mb"))
        let folder = directory.appendingPathComponent("Models/\(speech.id)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("fixture"), withIntermediateDirectories: true)
        try "fixture".write(to: folder.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
        var configuration = Configuration()
        let provider = ProviderConfiguration(model: "remote-speech", models: [.init(id: "remote-speech", category: .audio)])
        configuration.providers = [provider]; configuration.explicitRuleModels = true
        try ConfigurationStore(directory: directory).save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { model.shutdown() }
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "remote-speech"; rule.action?.audioProviderID = provider.id
        let host = NSHostingView(rootView: VStack {
            CompactRow(title: "Speech model") {
                RuleModelPicker(rule: Binding(get: { rule }, set: { rule = $0 }), speech: true)
            }
        }.padding(20).frame(width: 520, height: 460).environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 520, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await click(view: host, point: NSPoint(x: host.bounds.maxX - 130, y: host.bounds.midY))
        let popup = try XCTUnwrap(NSApplication.shared.windows.first { $0 != window && $0.isVisible })
        let view = try XCTUnwrap(popup.contentView)
        let field = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first)
        popup.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("remote-speech", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        try await click(view: view, point: NSPoint(x: view.bounds.midX + offset, y: view.isFlipped ? 79 : view.bounds.maxY - 79))
        try await click(view: view, point: NSPoint(x: view.bounds.midX, y: view.isFlipped ? 130 : view.bounds.maxY - 130))
        XCTAssertEqual(rule.action?.audioModelID, speech.id)
        XCTAssertNil(rule.action?.audioProviderID)
        XCTAssertTrue(model.localModels.loaded.isEmpty)
        XCTAssertFalse(model.localModels.busy)
    }

    private func click(view: NSView, point: NSPoint) async throws {
        let window = try XCTUnwrap(view.window)
        let point = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
