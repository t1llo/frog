import XCTest
import AppKit
import SwiftUI
import FrogCore
import FrogTestSupport
import FrogUsage
@testable import FrogApp

@MainActor final class ToolkitLifecycleTests: XCTestCase {
    func testDisablingWritingCancelsAProviderReplyBeforeClipboardDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ProviderConfiguration(kind: .ollama)
        let rule = Rule(name: "Fixture", providerID: provider.id)
        var config = Configuration(); config.providers = [provider]; config.defaultProviderID = provider.id; config.rules = [rule]
        try ConfigurationStore(directory: root).save(config)
        let gate = ToolkitReplyGate()
        var copied: [String] = []
        let model = AppModel(dataDirectory: root, registerShortcuts: false, complete: { _, _, _, _ in await gate.wait() },
            readKey: { _ in nil }, writeClipboard: { copied.append($0) })
        defer { model.shutdown() }
        model.processManual(text: "fixture", ruleID: rule.id)
        await gate.waitUntilStarted()
        try await model.setFeature(.writing, enabled: false)
        await gate.release()
        for _ in 0..<200 where model.isProcessing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isProcessing)
        XCTAssertTrue(copied.isEmpty, "A disabled tool's late result must never reach the clipboard")
        XCTAssertEqual(model.configuration.rules, [rule], "Disabling must retain rule settings")
    }
    func testDocumentFlushSavesLatestDebouncedEditBeforeQuit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LocalDocuments(directory: root)
        await model.load()
        var item = UtilityDocument(kind: .note, title: "Fixture", text: "old")
        model.add(item)
        item.text = "latest"; model.update(item)
        XCTAssertTrue(model.needsFlush)
        let flushed = await model.flush()
        XCTAssertTrue(flushed)
        let saved = try await UtilityDocumentStore(directory: root).load()
        XCTAssertEqual(saved.map(\.text), ["latest"])
        XCTAssertFalse(model.needsFlush)
    }
}

private actor ToolkitReplyGate {
    private var started = false
    private var start: CheckedContinuation<Void, Never>?
    private var reply: CheckedContinuation<String, Never>?
    func wait() async -> String {
        started = true; start?.resume(); start = nil
        return await withCheckedContinuation { reply = $0 }
    }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { start = $0 } } }
    func release() { reply?.resume(returning: "late fixture"); reply = nil }
}
