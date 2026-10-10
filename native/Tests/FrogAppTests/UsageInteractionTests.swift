import AppKit
import Combine
import XCTest
import FrogCore
import FrogUsage
@testable import FrogApp

@MainActor final class UsageInteractionTests: XCTestCase {
    func testRapidProviderChangesPersistTheLatestChoiceOnShutdown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "frog-usage-save-order-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        var configuration = Configuration(); configuration.preferences.setFeature(.usage, enabled: true)
        try ConfigurationStore(directory: root).save(configuration)
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: root.appendingPathComponent("fixtures"))
        let toolkit = Toolkit(makeUsage: { usage }, showsUsageStatusItem: false)
        let model = AppModel(dataDirectory: root, registerShortcuts: false, toolkit: toolkit)
        for index in 0..<41 {
            var next = usage.preferences; next.provider = index.isMultiple(of: 2) ? "OpenAI" : "Claude"
            usage.updatePreferences(next)
        }
        model.shutdown()
        XCTAssertEqual(try ConfigurationStore(directory: root).load().preferences.toolkit?.usage?.provider, "OpenAI")
    }

    func testDisplaySaveFailurePreservesExternalEditAndRestoresSavedProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "frog-usage-save-failure-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        var configuration = Configuration(); configuration.preferences.setFeature(.usage, enabled: true)
        try ConfigurationStore(directory: root).save(configuration)
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: root.appendingPathComponent("fixtures"))
        let toolkit = Toolkit(makeUsage: { usage }, showsUsageStatusItem: false)
        let model = AppModel(dataDirectory: root, registerShortcuts: false, toolkit: toolkit)
        defer { model.shutdown() }
        let file = root.appendingPathComponent("config")
        let edited = try String(contentsOf: file, encoding: .utf8) + "\n# External edit must survive\n"
        try edited.write(to: file, atomically: true, encoding: .utf8)
        var next = usage.preferences; next.provider = "OpenAI"; usage.updatePreferences(next)
        for _ in 0..<200 where model.errorMessage == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(usage.preferences.provider, "Claude")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited)
    }

    func testShutdownDrainsFailedDisplaySaveBeforeItsMainActorCallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "frog-usage-shutdown-failure-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        var configuration = Configuration(); configuration.preferences.setFeature(.usage, enabled: true)
        try ConfigurationStore(directory: root).save(configuration)
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: root.appendingPathComponent("fixtures"))
        let model = AppModel(dataDirectory: root, registerShortcuts: false,
            toolkit: Toolkit(makeUsage: { usage }, showsUsageStatusItem: false))
        let file = root.appendingPathComponent("config")
        let edited = try String(contentsOf: file, encoding: .utf8) + "\n# Preserve external change during shutdown\n"
        try edited.write(to: file, atomically: true, encoding: .utf8)
        var next = usage.preferences; next.provider = "OpenAI"; usage.updatePreferences(next)
        model.shutdown()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(usage.preferences.provider, "Claude")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited)
    }

    func testProviderSelectionDoesNotReloadUnrelatedHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "frog-usage-interaction-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        var configuration = Configuration()
        configuration.preferences.setFeature(.usage, enabled: true)
        configuration.rules = (0..<200).map { Rule(name: "Sample rule \($0)", instructions: "Rewrite the selected text.") }
        try ConfigurationStore(directory: root).save(configuration)
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: root.appendingPathComponent("fixtures"))
        let toolkit = Toolkit(makeUsage: { usage }, showsUsageStatusItem: false)
        let model = AppModel(dataDirectory: root, registerShortcuts: false, toolkit: toolkit)
        defer { model.shutdown() }
        var historyReloads = 0
        let observation = model.$history.dropFirst().sink { _ in historyReloads += 1 }
        defer { observation.cancel() }
        let start = ContinuousClock.now
        for provider in ["OpenAI", "Claude", "OpenAI"] {
            var preferences = usage.preferences; preferences.provider = provider
            usage.updatePreferences(preferences)
        }
        print("Usage provider selection, 200 saved rules, three switches: \(start.duration(to: .now))")
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(16), "Provider controls must not wait for configuration serialization/fsync")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(historyReloads, 0, "A display-only provider change must not reload history or reconfigure the toolkit")
        // A subsequent full save must drain queued display writes and keep both edits.
        var rule = configuration.rules[0]; rule.name = "Edited while provider writes were pending"
        try model.saveRule(rule)
        XCTAssertEqual(try ConfigurationStore(directory: root).load().preferences.toolkit?.usage?.provider, "OpenAI")
        XCTAssertEqual(try ConfigurationStore(directory: root).load().rules[0].name, rule.name)
        XCTAssertEqual(model.configuration.rules.dropFirst(), configuration.rules.dropFirst())
        var next = usage.preferences; next.provider = "Claude"; usage.updatePreferences(next)
        var imported = model.configuration
        imported.preferences.toolkit?.usage?.provider = "OpenAI"
        imported.rules[0].name = "Imported after a queued provider change"
        try model.importConfiguration(imported)
        model.shutdown()
        let saved = try ConfigurationStore(directory: root).load()
        XCTAssertEqual(saved.preferences.toolkit?.usage?.provider, "OpenAI", "Queued display writes cannot overwrite an import")
        XCTAssertEqual(saved.rules[0].name, imported.rules[0].name)
    }

    func testOutsideClickClosesUsagePopoverAndInsideClickKeepsItOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "frog-usage-popover-\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: root)
        let controller = UsageStatusItemController(usage: usage, openDashboard: {})
        defer { controller.stop() }
        let outside = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 160, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        outside.isReleasedWhenClosed = false
        outside.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
        outside.orderFront(nil)
        defer { outside.orderOut(nil) }
        let anchor = NSWindow(contentRect: NSRect(x: 400, y: 500, width: 50, height: 30), styleMask: .borderless, backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
        anchor.orderFront(nil)
        defer { anchor.orderOut(nil) }
        controller.showPopover(relativeTo: try XCTUnwrap(anchor.contentView))
        for _ in 0..<100 where !controller.popover.isShown { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(controller.popover.isShown)
        let window = try XCTUnwrap(controller.popover.contentViewController?.view.window)
        func click(_ target: NSWindow) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 15, y: 15), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                NSApplication.shared.sendEvent(event)
            }
        }
        try click(window)
        XCTAssertTrue(controller.popover.isShown, "Interacting inside must not dismiss the popup")
        try click(outside)
        for _ in 0..<100 where controller.popover.isShown { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(controller.popover.isShown, "Clicking another Frog window must dismiss the popup too")
    }
}
