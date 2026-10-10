import AppKit
import XCTest
import FrogCore
@testable import FrogApp

@MainActor final class CommandBarTests: XCTestCase {
    func testClosingDuringIndexingRejectsLateAppsAndReleasesResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.preferences.setFeature(.commandBar, enabled: true)
        config.preferences.windowSwitcherEnabled = false
        try ConfigurationStore(directory: root).save(config)
        let model = AppModel(dataDirectory: root, registerShortcuts: false)
        defer { model.shutdown() }
        let gate = CommandIndexGate()
        let bar = CommandBar(model: model, fileScopes: [root], captureTarget: { nil }, loadApplications: { await gate.wait() })
        bar.show()
        await gate.started()
        bar.hide()
        await gate.release()
        await Task.yield()
        XCTAssertTrue(bar.results.isEmpty)
    }

    func testSensitiveClipboardIsExcludedAndSnippetInsertionUsesNativeDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration()
        for feature in [FeatureID.commandBar, .snippets, .clipboard] { config.preferences.setFeature(feature, enabled: true) }
        config.preferences.windowSwitcherEnabled = false
        try ConfigurationStore(directory: root).save(config)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let history = ClipboardHistoryStore(pasteboard: pasteboard)
        let model = AppModel(dataDirectory: root, registerShortcuts: false, clipboardHistoryStore: history)
        model.start(); defer { model.shutdown() }
        _ = ClipboardHistoryEntry(text: "sensitive-fixture", isSensitive: true).write(to: pasteboard, plainText: true)
        await history.poll()
        await model.documents.load()
        let snippet = UtilityDocument(kind: .snippet, title: "Greeting fixture", text: "Hello {{clipboard}}")
        model.documents.add(snippet)
        let target = CommandPasteTarget()
        let bar = CommandBar(model: model, pasteboard: pasteboard, fileScopes: [root], captureTarget: { target }, waitForRelease: {}, loadApplications: { [] })
        defer { bar.hide() }
        bar.show()
        for _ in 0..<100 where !bar.results.contains(where: { $0.id == "snippet:\(snippet.id)" }) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(bar.results.contains { $0.title.contains("sensitive-fixture") })
        bar.query = "Greeting fixture"
        bar.choose()
        for _ in 0..<100 where target.pastes == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(target.pastes, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello sensitive-fixture")
        XCTAssertTrue(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
        _ = await model.flushDocuments()
    }
    func testNativeReturnExecutesCalculatorAndEscapeDismissesWithoutCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.preferences.setFeature(.commandBar, enabled: true)
        config.preferences.windowSwitcherEnabled = false
        try ConfigurationStore(directory: root).save(config)
        let model = AppModel(dataDirectory: root, registerShortcuts: false)
        defer { model.shutdown() }
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("unchanged", forType: .string)
        let bar = CommandBar(model: model, pasteboard: pasteboard, fileScopes: [root], captureTarget: { nil }, loadApplications: { [] })
        defer { bar.hide() }
        bar.show()
        try await Task.sleep(for: .milliseconds(120))
        bar.query = "(3+4)*6"
        XCTAssertEqual(bar.results.first?.title, "42")
        let panel = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "Frog command bar" && $0.isVisible })
        try send(36, to: panel)
        for _ in 0..<100 where pasteboard.string(forType: .string) != "42" { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(pasteboard.string(forType: .string), "42")
        XCTAssertFalse(panel.isVisible)
        bar.show(); try await Task.sleep(for: .milliseconds(120))
        bar.query = "8*8"
        let next = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "Frog command bar" && $0.isVisible })
        try send(53, to: next)
        XCTAssertFalse(next.isVisible)
        XCTAssertEqual(pasteboard.string(forType: .string), "42")
    }
    private func send(_ key: UInt16, to window: NSWindow) throws {
        NSApplication.shared.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: key == 36 ? "\r" : "\u{1b}", charactersIgnoringModifiers: key == 36 ? "\r" : "\u{1b}", isARepeat: false, keyCode: key)))
    }
}

@MainActor private final class CommandPasteTarget: ClipboardHistoryPasteTarget {
    var pastes = 0
    func paste() throws { pastes += 1 }
}
private actor CommandIndexGate {
    private var waiting: CheckedContinuation<[Rule], Never>?
    private var start: CheckedContinuation<Void, Never>?
    func wait() async -> [Rule] {
        await withCheckedContinuation { waiting = $0; start?.resume(); start = nil }
    }
    func started() async { if waiting == nil { await withCheckedContinuation { start = $0 } } }
    func release() {
        var rule = Rule(name: "Late app"); rule.action = RuleAction(category: .application)
        rule.action?.applicationPath = "/fixture/Late.app"
        waiting?.resume(returning: [rule]); waiting = nil
    }
}
