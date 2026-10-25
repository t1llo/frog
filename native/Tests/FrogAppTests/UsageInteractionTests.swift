import AppKit
import Combine
import XCTest
import FrogCore
import FrogTestSupport
import FrogUsage
@testable import FrogApp

@MainActor final class UsageInteractionTests: XCTestCase {
    func testRapidProviderChangesPersistTheLatestChoiceOnShutdown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = temporaryDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
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

    /// What a click on a design tile does: Mr. Usage's goes through the usage model, the CPU and
    /// GPU and Stay awake ones save the preferences. Each must reach the file and stay chosen.
    func testChosenMenuBarDesignsReachTheConfigurationAndStayChosen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = temporaryDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = Configuration(); configuration.preferences.setFeature(.usage, enabled: true)
        try ConfigurationStore(directory: root).save(configuration)
        let usage = UsageDashboardModel(defaults: defaults, fixtureRoot: root.appendingPathComponent("fixtures"))
        let toolkit = Toolkit(makeUsage: { usage }, showsUsageStatusItem: false)
        let model = AppModel(dataDirectory: root, registerShortcuts: false, toolkit: toolkit)
        defer { model.shutdown() }

        var next = usage.preferences; next.menuBarStyle = "bars"; next.menuBarPalette = "level"
        usage.updatePreferences(next)
        var preferences = model.configuration.preferences
        preferences.ensureToolkit()
        preferences.toolkit?.systemMonitor = SystemMonitorPreferences(menuBarItem: true, menuBarStyle: "columns")
        preferences.toolkit?.stayAwake = StayAwakePreferences(menuBarItem: true, menuBarStyle: "time")
        try model.savePreferences(preferences)

        XCTAssertEqual(usage.preferences.menuBarStyle, "bars", "Saving the other choices must not undo Mr. Usage's")
        XCTAssertEqual(usage.preferences.menuBarPalette, "level")
        let text = try String(contentsOf: root.appendingPathComponent("config"), encoding: .utf8)
        for line in ["usage.menu-bar-style = bars", "usage.menu-bar-palette = level", "system-monitor.menu-bar = true",
                     "system-monitor.menu-bar-style = columns", "stay-awake.menu-bar = true", "stay-awake.menu-bar-style = time"] {
            XCTAssertTrue(text.contains(line), line)
        }
        try model.reloadConfiguration()
        XCTAssertEqual(usage.preferences.menuBarStyle, "bars")
        XCTAssertEqual(model.configuration.preferences.toolkitSettings.systemMonitor?.menuBarStyle, "columns")
        XCTAssertEqual(model.configuration.preferences.toolkitSettings.stayAwake?.menuBarStyle, "time")
    }

    func testDisplaySaveFailurePreservesExternalEditAndRestoresSavedProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = temporaryDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let defaults = temporaryDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let defaults = temporaryDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let defaults = temporaryDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
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
        controller.showPopup(relativeTo: try XCTUnwrap(anchor.contentView))
        for _ in 0..<100 where !controller.isPopupShown { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(controller.isPopupShown)
        let window = try XCTUnwrap(controller.popup)
        func click(_ target: NSWindow) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 15, y: 15), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                NSApplication.shared.sendEvent(event)
            }
        }
        try click(window)
        XCTAssertTrue(controller.isPopupShown, "Interacting inside must not dismiss the popup")
        try click(outside)
        for _ in 0..<100 where controller.isPopupShown { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(controller.isPopupShown, "Clicking another Frog window must dismiss the popup too")

        // Same surface as Frog's menu-bar popup: a plain panel beneath the item, no popover arrow.
        var opened: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: .frogMenuPopupWillOpen, object: nil, queue: nil) { note in
            (note.object as? String).map { opened.append($0) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let anchorView = try XCTUnwrap(anchor.contentView)
        controller.showPopup(relativeTo: anchorView)
        XCTAssertEqual(opened, [UsageStatusPopover.popupName], "Opening tells Frog's own popup to close")
        let panel = try XCTUnwrap(controller.popup)
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.frame.width, UsageStatusPopover.width)
        XCTAssertEqual(panel.frame.minX, anchor.frame.minX, "Left-aligned with the status item")
        XCTAssertEqual(panel.frame.maxY, anchor.frame.minY - 5)
        NotificationCenter.default.post(name: .frogMenuPopupWillOpen, object: UsageStatusPopover.popupName)
        XCTAssertTrue(controller.isPopupShown)
        NotificationCenter.default.post(name: .frogMenuPopupWillOpen, object: FrogStatusMenu.popupName)
        for _ in 0..<100 where controller.isPopupShown { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(controller.isPopupShown, "Opening Frog's popup closes this one")
    }

    func testMenuBarReadoutFallsBackToThePeriodEstimateInsteadOfOnlyAName() {
        let name = UsageStatusReadout.image(provider: "Claude", windows: [])
        let estimate = UsageStatusReadout.Estimate(range: "7d", value: "$185")
        let fallback = UsageStatusReadout.image(provider: "Claude", windows: [], estimate: estimate)
        XCTAssertTrue(fallback.isTemplate)
        XCTAssertNotEqual(fallback.size.width, name.size.width)
        XCTAssertEqual(UsageStatusReadout.description(provider: "Claude", windows: [], estimate: estimate),
                       "Mr. Usage · Claude\nAPI estimate, last 7d: $185")
    }
}
