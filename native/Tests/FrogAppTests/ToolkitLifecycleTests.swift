import XCTest
import AppKit
import SwiftUI
import FrogCore
import FrogUsage
@testable import FrogApp

@MainActor final class ToolkitLifecycleTests: XCTestCase {
    func testClosingDashboardKeepsEnabledStatusItemAndCollectionAlive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "frog-toolkit-visible-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: root)
        let toolkit = Toolkit(makeUsage: { usage })
        defer { toolkit.stop() }
        var prefs = Preferences(); prefs.setFeature(.usage, enabled: true)
        toolkit.apply(prefs)
        let statusItem = try XCTUnwrap(toolkit.usageStatusItem)
        XCTAssertTrue(statusItem.isInstalled)
        let host = NSHostingView(rootView: UsageDashboardView(usage: usage))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.orderFrontRegardless()
        XCTAssertTrue(usage.active)
        window.close()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(usage.active, "The status item keeps collecting when the dashboard closes")
        XCTAssertTrue(statusItem.isInstalled)
        XCTAssertTrue(window.contentView === host)
        prefs.setFeature(.usage, enabled: false); toolkit.apply(prefs)
        XCTAssertFalse(usage.active)
        XCTAssertFalse(statusItem.isInstalled)
        XCTAssertNil(toolkit.usageStatusItem)
    }
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
    func testFeatureDisableRemovesItsRouteAndStopsItsExistingUsageModule() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "frog-toolkit-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var constructions = 0
        let toolkit = Toolkit(makeUsage: { constructions += 1; return UsageDashboardModel(defaults: defaults, fixtureRoot: root) }, showsUsageStatusItem: false)
        defer { toolkit.stop() }
        var prefs = Preferences()
        toolkit.apply(prefs)
        XCTAssertEqual(constructions, 0, "Disabled usage never constructs a collector or scans")
        prefs.setFeature(.usage, enabled: true)
        toolkit.apply(prefs)
        XCTAssertEqual(constructions, 1, "Enabling immediately starts the status item's collection")
        toolkit.select(.feature(.usage))
        let usage = try XCTUnwrap(toolkit.usage())
        XCTAssertTrue(usage.active)
        prefs.setFeature(.usage, enabled: false); toolkit.apply(prefs)
        XCTAssertFalse(usage.active)
        usage.setActive(true)
        XCTAssertFalse(usage.active, "A late native visibility callback cannot restart a disabled module")
        XCTAssertFalse(toolkit.sidebar.contains(.usage))
        XCTAssertEqual(toolkit.route, .features)
        XCTAssertNil(toolkit.usage())
        prefs.setFeature(.usage, enabled: true); toolkit.apply(prefs)
        XCTAssertTrue(toolkit.usage() === usage)
        XCTAssertTrue(usage.active)
        XCTAssertEqual(constructions, 1)
        toolkit.stop()
        XCTAssertFalse(usage.active)
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
