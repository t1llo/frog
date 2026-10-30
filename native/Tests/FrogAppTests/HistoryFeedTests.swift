import AppKit
import SwiftUI
import FrogCore
import XCTest
@testable import FrogApp

@MainActor
final class HistoryFeedTests: XCTestCase {
    func testTheFeedKindsSavedEntriesAndListsThemNewestFirst() {
        let written = HistoryEntry(timestamp: Date(timeIntervalSince1970: 10), originalText: "Original", processedText: "Result", ruleName: "Proofread", providerName: "Local", model: "fixture")
        var dictated = HistoryEntry(timestamp: Date(timeIntervalSince1970: 20), originalText: "", processedText: "Spoken", ruleName: "Dictation", providerName: "Local", model: "fixture")
        dictated.category = .audio
        var answered = HistoryEntry(timestamp: Date(timeIntervalSince1970: 30), originalText: "bank", processedText: "Land by a river.", ruleName: "Explain", providerName: "Local", model: "fixture")
        answered.answer = AnswerRecord(context: nil, application: nil, source: nil, followUps: [])
        XCTAssertEqual(HistoryFeed.items([written, dictated, answered]).map(\.kind), [.answers, .audio, .text])
    }

    /// Copied text is the Clipboard plugin's: it never enters History, and History's delete and clear leave it alone.
    func testHistoryAndTheClipboardKeepApart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        var configuration = Configuration()
        configuration.preferences.historyEnabled = true
        try ConfigurationStore(directory: directory).save(configuration)
        let saved = HistoryEntry(originalText: "Original", processedText: "Saved result", ruleName: "Proofread", providerName: "Local", model: "fixture")
        let other = HistoryEntry(originalText: "Other", processedText: "Other result", ruleName: "Proofread", providerName: "Local", model: "fixture")
        try HistoryStore(directory: directory).append(saved, preferences: configuration.preferences)
        try HistoryStore(directory: directory).append(other, preferences: configuration.preferences)
        let clipboard = ClipboardHistoryStore(pasteboard: pasteboard)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, clipboardHistoryStore: clipboard)
        defer { model.shutdown() }
        model.start()
        clipboard.configure(enabled: true, automaticallyPoll: false)
        clipboard.recordCopiedText("Private copied value")
        XCTAssertEqual(Set(model.history.map(\.id)), [saved.id, other.id])
        XCTAssertTrue(model.historyEntries(search: "Private copied value").isEmpty)
        try model.deleteHistory(id: saved.id)
        XCTAssertEqual(model.history.map(\.id), [other.id])
        XCTAssertEqual(clipboard.entries.map(\.text), ["Private copied value"])
        try model.clearHistory()
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertEqual(clipboard.entries.map(\.text), ["Private copied value"], "Clearing History leaves the clipboard alone")
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

    func testAFailedHistoryClearLeavesTheClipboardAlone() throws {
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
        XCTAssertEqual(clipboard.entries.map(\.text), ["Synthetic private value"])
        XCTAssertEqual(clipboard.retentionGeneration, generation)
    }

    func testACopiedAudioTranscriptReachesTheClipboardButNotHistoryWhileHistoryIsOff() async throws {
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
        await model.pluginHost.syncAndWait()
        var rule = Rule.dictationPreset
        rule.action?.audioModelID = "fixture-speech"; rule.action?.audioProviderID = UUID()
        rule.action?.showRecordingPopup = false; rule.action?.output = .copy
        controller.externalTranscription = { _, _ in "Copied audio transcript" }
        model.startDictation(rule); await controller.waitForWork()
        controller.stop(models: model.localModels); await controller.waitForWork()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(clipboard.entries.map(\.text), ["Copied audio transcript"])
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertTrue(try HistoryStore(directory: directory).load(preferences: configuration.preferences).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path))
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
    func start(deviceUID: String?, samples: @escaping @Sendable ([Float]) -> Void) throws { samples(Array(repeating: 0.1, count: 8000)) }
    func stop() {}
}
