import AppKit
import SwiftUI
import FrogCore
import XCTest
@testable import FrogApp

@MainActor
final class HistoryFeedTests: XCTestCase {
    func testMergedFeedTagsClipboardAndProtectsHiddenSearch() {
        let saved = HistoryEntry(timestamp: Date(timeIntervalSince1970: 10), originalText: "Original", processedText: "Result", ruleName: "Proofread", providerName: "Local", model: "fixture")
        let copied = ClipboardHistoryEntry(text: "A synthetic secret", isSensitive: true, timestamp: Date(timeIntervalSince1970: 20))
        let feed = HistoryFeed.items(saved: [saved], clipboard: [copied])
        XCTAssertEqual(feed.map(\.filter), [.clipboard, .text])
        XCTAssertEqual(feed.first?.id, copied.id)
        XCTAssertEqual(feed.first?.requiresReveal, true)
        XCTAssertEqual(HistoryFeed.items(saved: [saved], clipboard: [copied], filter: .clipboard).count, 1)
        XCTAssertTrue(HistoryFeed.items(saved: [], clipboard: [copied], search: "synthetic secret").isEmpty)
        XCTAssertEqual(HistoryFeed.items(saved: [], clipboard: [copied], search: "synthetic secret", revealed: [copied.id]).count, 1)
        XCTAssertEqual(HistoryFeed.items(saved: [], clipboard: [copied], search: "Clipboard").count, 1)
        XCTAssertFalse(copied.displayPreview(revealed: false).contains("secret"))
        XCTAssertTrue(copied.displayPreview(revealed: true).contains("secret"))
        let ordinary = ClipboardHistoryEntry(text: "Ordinary copied text")
        XCTAssertFalse(ordinary.displayPreview(revealed: false).contains("Ordinary"), "All copied previews start masked, not just marked passwords")
    }

    func testClipboardFeedRemainsMemoryOnlyWithSavedHistoryEnabledAndCanBeDeletedClearedAndDisabled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        var configuration = Configuration()
        configuration.preferences.historyEnabled = true
        configuration.preferences.workflows = WorkflowPreferences()
        configuration.preferences.workflows?.clipboardHistoryEnabled = true
        try ConfigurationStore(directory: directory).save(configuration)
        let saved = HistoryEntry(originalText: "Original", processedText: "Saved result", ruleName: "Proofread", providerName: "Local", model: "fixture")
        try HistoryStore(directory: directory).append(saved, preferences: configuration.preferences)
        let clipboard = ClipboardHistoryStore(pasteboard: pasteboard)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, clipboardHistoryStore: clipboard)
        defer { model.shutdown() }
        model.start()
        pasteboard.clearContents(); pasteboard.setString("Private copied value", forType: .string); await clipboard.poll()
        XCTAssertEqual(HistoryFeed.items(saved: model.history, clipboard: clipboard.entries).count, 2)
        XCTAssertEqual(try HistoryStore(directory: directory).load(preferences: configuration.preferences), [saved])
        XCTAssertFalse(String(decoding: try ConfigurationFile.encode(model.configuration), as: UTF8.self).contains("Private copied value"))
        let id = try XCTUnwrap(clipboard.entries.first?.id)
        try model.deleteHistory(id: id)
        XCTAssertTrue(clipboard.entries.isEmpty)
        XCTAssertEqual(model.history, [saved])
        clipboard.recordCopiedText("Another copied value")
        try model.clearHistory()
        XCTAssertTrue(model.history.isEmpty); XCTAssertTrue(clipboard.entries.isEmpty)
        clipboard.recordCopiedText("Forget on disable")
        var workflow = model.configuration.preferences.workflowSettings; workflow.clipboardHistoryEnabled = false
        try model.saveWorkflowPreferences(workflow)
        XCTAssertTrue(clipboard.entries.isEmpty)
        let reloaded = AppModel(dataDirectory: directory, registerShortcuts: false)
        defer { reloaded.shutdown() }
        XCTAssertTrue(reloaded.clipboardHistoryStore.entries.isEmpty)
    }

    func testWritingResultSurvivesCompatibilityCopySuppressionAndStaysOutOfSavedHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let provider = ProviderConfiguration(kind: .ollama)
        let rule = Rule(name: "Copy result", providerID: provider.id, model: provider.model)
        var configuration = Configuration()
        configuration.providers = [provider]; configuration.rules = [rule]
        configuration.preferences.workflows = WorkflowPreferences()
        configuration.preferences.workflows?.clipboardHistoryEnabled = true
        try ConfigurationStore(directory: directory).save(configuration)
        let clipboard = ClipboardHistoryStore(pasteboard: pasteboard)
        let selection = ClipboardFixtureSelection(pasteboard: pasteboard)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, complete: { _, _, _, _ in "Final generated result" },
            readKey: { _ in nil }, captureSelection: { selection }, clipboardHistoryStore: clipboard)
        defer { model.shutdown() }
        model.start(); model.processSelection(ruleID: rule.id)
        for _ in 0..<200 where model.isProcessing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isProcessing); XCTAssertNil(model.errorMessage)
        await clipboard.poll()
        XCTAssertEqual(clipboard.entries.map(\.text), ["Final generated result"])
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertTrue(try HistoryStore(directory: directory).load(preferences: configuration.preferences).isEmpty)
    }

    func testDiskClearFailureStillForgetsClipboardMemory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let clipboard = ClipboardHistoryStore(pasteboard: pasteboard)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, clipboardHistoryStore: clipboard)
        defer { model.shutdown() }
        clipboard.configure(enabled: true, automaticallyPoll: false)
        clipboard.recordCopiedText("Synthetic private value")
        let generation = clipboard.retentionGeneration
        // A nonempty directory in place of the file causes unlink to fail,
        // without permissions changes or touching any real saved history.
        let blocked = directory.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: blocked.appendingPathComponent("child"))
        XCTAssertThrowsError(try model.clearHistory())
        XCTAssertTrue(clipboard.entries.isEmpty)
        XCTAssertNotEqual(clipboard.retentionGeneration, generation)
    }

    func testCopiedAudioTranscriptAppearsInClipboardFeedEvenWhenSavedHistoryIsOff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        var configuration = Configuration()
        configuration.preferences.workflows = WorkflowPreferences()
        configuration.preferences.workflows?.clipboardHistoryEnabled = true
        try ConfigurationStore(directory: directory).save(configuration)
        let clipboard = ClipboardHistoryStore(pasteboard: pasteboard)
        let controller = DictationController(makeRecorder: { ClipboardFixtureRecording() }, authorize: { true }, copy: {
            pasteboard.clearContents(); pasteboard.setString($0, forType: .string)
        }, monitorKeys: false)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, dictationController: controller, clipboardHistoryStore: clipboard)
        defer { model.shutdown() }
        model.start()
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "fixture-speech"; rule.action?.audioProviderID = UUID()
        rule.action?.showRecordingPopup = false; rule.action?.output = .copy
        controller.externalTranscription = { _, _ in "Copied audio transcript" }
        model.startDictation(rule); await controller.waitForWork()
        controller.stop(models: model.localModels); await controller.waitForWork()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(clipboard.entries.map(\.text), ["Copied audio transcript"])
        XCTAssertEqual(HistoryFeed.items(saved: model.history, clipboard: clipboard.entries).map(\.filter), [.clipboard])
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertTrue(try HistoryStore(directory: directory).load(preferences: configuration.preferences).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path))
    }

    func testNativeHistoryMasksRevealsAndRemasksClipboardOnlyFeedWithoutPersistingIt() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        var configuration = Configuration()
        configuration.preferences.workflows = WorkflowPreferences()
        configuration.preferences.workflows?.clipboardHistoryEnabled = true
        try ConfigurationStore(directory: directory).save(configuration)
        let clipboard = ClipboardHistoryStore(pasteboard: pasteboard)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, clipboardHistoryStore: clipboard)
        defer { model.shutdown() }
        model.start()
        clipboard.recordCopiedText("Synthetic clipboard text — visible only after clicking.")
        let entry = try XCTUnwrap(clipboard.entries.first)
        let visibility = HistoryVisibility()
        let host = NSHostingView(rootView: HistoryView(visibility: visibility).environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 700, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(50)); host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(descendants(host).first { $0 is NSScrollView }, "Clipboard-only history must show rows, not the empty-history state")
        XCTAssertTrue(visibility.revealed.isEmpty)
        try snapshot(host, suffix: "masked")
        let point = host.convert(NSPoint(x: 100, y: host.isFlipped ? 165 : host.bounds.maxY - 165), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(50)); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(visibility.revealed, [entry.id], "Opening a clipboard row is an explicit reveal")
        try snapshot(host, suffix: "revealed")
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        try await Task.sleep(for: .milliseconds(30)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(visibility.revealed.isEmpty, "Closing History must forget reveal state")
        try snapshot(host, suffix: "remasked")
        XCTAssertTrue(model.history.isEmpty, "Showing or revealing a copied item must not persist it")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func snapshot(_ view: NSView, suffix: String) throws {
        guard let root = ProcessInfo.processInfo.environment["FROG_TEST_HISTORY_SNAPSHOT"] else { return }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: root + "-" + suffix + ".png"))
    }
}

@MainActor
private final class ClipboardFixtureSelection: CapturedTextSelection {
    let text = "Selected input"
    let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    func replace(with text: String) async throws {
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        _ = try await FreshSelectionCopy.read(pasteboard: pasteboard) {
            pasteboard.clearContents(); pasteboard.setString(self.text, forType: .string)
        }
    }
}

@MainActor
private final class ClipboardFixtureRecording: DictationRecording {
    func start(device: UInt32?, samples: @escaping @Sendable ([Float]) -> Void) throws { samples(Array(repeating: 0.1, count: 8000)) }
    func stop() {}
}
