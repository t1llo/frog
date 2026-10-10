import AppKit
import XCTest
import FrogCore
@testable import FrogApp

@MainActor final class CommandBarTests: XCTestCase {
    func testOpenedFileIsImmediatelySuggestedButCancelledOpeningIsNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.preferences.setFeature(.commandBar, enabled: true)
        config.preferences.windowSwitcherEnabled = false
        try ConfigurationStore(directory: root).save(config)
        let model = AppModel(dataDirectory: root, registerShortcuts: false)
        defer { model.shutdown() }
        let files = CommandFileFixture(), gate = CommandIndexGate()
        var waits = false, opened: [URL] = []
        let bar = CommandBar(model: model, fileScopes: [root], captureTarget: { nil }, waitForRelease: {
            if waits { _ = await gate.wait() }
        }, fileSearch: files, openFile: { opened.append($0); return true }, loadApplications: { [] })
        defer { bar.stop() }
        bar.show(); bar.query = "Project"
        let chosen = SearchRecord(id: "file:/fixture/Project notes.txt", title: "Project notes.txt")
        try await files.request("Project").receive([chosen])
        bar.choose(try XCTUnwrap(bar.results.firstIndex { $0.id == chosen.id }))
        for _ in 0..<100 where opened.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(opened, [URL(fileURLWithPath: "/fixture/Project notes.txt")])
        bar.show()
        // Spotlight may not yet have recorded the open, or may be unavailable.
        files.requests.last?.receive([])
        XCTAssertEqual(bar.results.first?.id, chosen.id)
        waits = true
        bar.query = "Cancelled"
        let cancelled = SearchRecord(id: "file:/fixture/Cancelled.txt", title: "Cancelled.txt")
        try await files.request("Cancelled").receive([cancelled])
        bar.choose(try XCTUnwrap(bar.results.firstIndex { $0.id == cancelled.id }))
        await gate.started()
        bar.show()
        await gate.release()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(bar.results.first?.id, chosen.id)
        XCTAssertFalse(bar.results.contains { $0.id == cancelled.id })
    }

    func testIconRequestsAreCoalescedAndClosingRejectsPendingImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.preferences.windowSwitcherEnabled = false
        try ConfigurationStore(directory: root).save(config)
        let model = AppModel(dataDirectory: root, registerShortcuts: false)
        defer { model.shutdown() }
        let reader = CommandIconFixture()
        let bar = CommandBar(model: model, loadIcon: { reader.load($0) }, fileSearch: CommandFileFixture(), loadApplications: { [] })
        defer { bar.stop() }
        let record = SearchRecord(id: "app:/fixture/Icon.app", title: "Icon")
        let first = Task { await bar.icon(for: record) }
        for _ in 0..<100 where reader.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let second = Task { await bar.icon(for: record) }
        await Task.yield()
        reader.release.signal()
        let firstImage = await first.value, secondImage = await second.value
        XCTAssertNotNil(firstImage)
        XCTAssertTrue(firstImage === secondImage)
        XCTAssertEqual(reader.count, 1)
        _ = await bar.icon(for: record)
        XCTAssertEqual(reader.count, 1, "A returning row uses the icon cache")
        let pending = Task { await bar.icon(for: SearchRecord(id: "app:/fixture/Other.app", title: "Other")) }
        for _ in 0..<100 where reader.count == 1 { try await Task.sleep(for: .milliseconds(5)) }
        let scrolledAway = Task { await bar.icon(for: SearchRecord(id: "app:/fixture/ScrolledAway.app", title: "Scrolled away")) }
        await Task.yield()
        scrolledAway.cancel()
        await Task.yield()
        bar.hide()
        reader.release.signal()
        let cancelledImage = await pending.value
        XCTAssertNil(cancelledImage)
        let discardedImage = await scrolledAway.value
        XCTAssertNil(discardedImage)
        XCTAssertEqual(reader.count, 2, "Cancelled rows must not perform queued icon reads")
    }

    func testCatalogueRefreshRemovesUninstalledAppsAndReplacesRenamedApps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.preferences.setFeature(.commandBar, enabled: true)
        config.preferences.windowSwitcherEnabled = false
        try ConfigurationStore(directory: root).save(config)
        let model = AppModel(dataDirectory: root, registerShortcuts: false)
        defer { model.shutdown() }
        var original = Rule(name: "Original"); original.action = RuleAction(category: .application)
        original.action?.applicationPath = "/fixture/Original.app"
        var removed = Rule(name: "Removed"); removed.action = RuleAction(category: .application)
        removed.action?.applicationPath = "/fixture/Removed.app"
        var renamed = original; renamed.name = "Renamed"
        let gate = CommandIndexGate()
        var loads = 0
        let bar = CommandBar(model: model, captureTarget: { nil }, fileSearch: CommandFileFixture(), loadApplications: {
            loads += 1
            return loads == 1 ? [original, removed] : await gate.wait()
        })
        defer { bar.stop() }
        bar.warm()
        for _ in 0..<100 where loads == 0 { try await Task.sleep(for: .milliseconds(5)) }
        bar.show()
        XCTAssertTrue(bar.results.contains { $0.title == "Original" })
        await gate.started(); await gate.release([renamed])
        for _ in 0..<100 where !bar.results.contains(where: { $0.title == "Renamed" }) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(bar.results.contains { $0.title == "Renamed" })
        XCTAssertFalse(bar.results.contains { ["Original", "Removed"].contains($0.title) })
    }

    func testFilesArriveIndependentlyOfAppRefreshAndKeepKeyboardChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.preferences.setFeature(.commandBar, enabled: true)
        config.preferences.windowSwitcherEnabled = false
        try ConfigurationStore(directory: root).save(config)
        let model = AppModel(dataDirectory: root, registerShortcuts: false)
        defer { model.shutdown() }
        let files = CommandFileFixture(), gate = CommandIndexGate()
        let bar = CommandBar(model: model, fileScopes: [root], captureTarget: { nil }, fileSearch: files, loadApplications: { await gate.wait() })
        defer { bar.stop() }
        bar.show()
        await gate.started()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(files.requests.map(\.text), [""])
        let recent = SearchRecord(id: "file:/fixture/Weekly plan.txt", title: "Weekly plan.txt", subtitle: "Documents")
        files.requests[0].receive([recent])
        XCTAssertTrue(bar.results.prefix(4).contains(recent), "Fresh startup documents must be visible alongside actions")
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Frog command bar" && $0.isVisible })
        try send(125, to: panel)
        let selected = bar.results[bar.selection].id
        await gate.release()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(files.requests.count, 1, "An unrelated app refresh must not restart Spotlight or its debounce")
        XCTAssertEqual(bar.results[bar.selection].id, selected)
        bar.query = "Weekly"
        let weeklyRequest = try await files.request("Weekly")
        bar.query = "Late app"
        let exact = SearchRecord(id: "file:/fixture/Late app", title: "Late app", subtitle: "Folder", symbol: "folder")
        try await files.request("Late app").receive([exact])
        XCTAssertTrue(bar.results.prefix(2).contains(exact), "Exact files must compete with apps rather than trail all app matches")
        XCTAssertTrue(bar.results.prefix(2).contains { $0.id.hasPrefix("app:") })
        XCTAssertEqual(bar.results[bar.selection].id, exact.id, "Without manual navigation, Return follows the best arriving match")
        let valid = bar.results
        weeklyRequest.receive([recent])
        XCTAssertEqual(bar.results, valid, "A superseded search must not replace newer results")
        bar.hide()
        files.requests.last?.receive([exact])
        XCTAssertTrue(bar.results.isEmpty)
    }

    func testEditingQuerySelectsBestMatchInsteadOfRetainingOldKeyboardChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.preferences.setFeature(.commandBar, enabled: true)
        config.preferences.windowSwitcherEnabled = false
        try ConfigurationStore(directory: root).save(config)
        let model = AppModel(dataDirectory: root, registerShortcuts: false)
        defer { model.shutdown() }
        let apps = ["Sample", "Sample Two"].map { name in
            var rule = Rule(name: name); rule.action = RuleAction(category: .application)
            rule.action?.applicationPath = "/fixture/\(name).app"; return rule
        }
        let bar = CommandBar(model: model, captureTarget: { nil }, fileSearch: CommandFileFixture(), loadApplications: { apps })
        defer { bar.stop() }
        bar.show()
        for _ in 0..<100 where !bar.results.contains(where: { $0.id.hasPrefix("app:") }) { try await Task.sleep(for: .milliseconds(5)) }
        bar.query = "Sample"
        bar.selection = 1
        bar.query = "Sam"
        XCTAssertEqual(bar.selection, 0)
        XCTAssertEqual(bar.results[bar.selection].title, "Sample")
    }

    func testSpotlightPredicateMatchesSyntheticDocumentsAndFoldersOnly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ name: String, _ types: [String], daysAgo: Double = 0) -> [String: Any] {
            ["kMDItemFSName": name, "kMDItemContentTypeTree": types, "kMDItemLastUsedDate": now.addingTimeInterval(-daysAgo * 86400)]
        }
        let document = item("Café project.txt", ["public.content", "public.plain-text"])
        let folder = item("Café project", ["public.folder"])
        let app = item("Café project.app", ["public.folder", "com.apple.application-bundle"])
        let recent = MetadataCommandFileSearch.predicate(text: "", now: now)
        XCTAssertTrue(recent.evaluate(with: document)); XCTAssertTrue(recent.evaluate(with: folder))
        XCTAssertFalse(recent.evaluate(with: app))
        XCTAssertFalse(recent.evaluate(with: item("Old.txt", ["public.content"], daysAgo: 8)))
        let named = MetadataCommandFileSearch.predicate(text: "project CAFE", now: now)
        XCTAssertTrue(named.evaluate(with: document)); XCTAssertTrue(named.evaluate(with: folder))
        XCTAssertFalse(named.evaluate(with: app))
        XCTAssertFalse(named.evaluate(with: item("Other project.txt", ["public.content"])))
    }

    func testSyntheticCatalogueInteractionTiming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.preferences.setFeature(.commandBar, enabled: true)
        config.preferences.windowSwitcherEnabled = false
        try ConfigurationStore(directory: root).save(config)
        let model = AppModel(dataDirectory: root, registerShortcuts: false)
        defer { model.shutdown() }
        let apps = (0..<2000).map { index in
            var rule = Rule(name: "Synthetic App \(index)"); rule.action = RuleAction(category: .application)
            rule.action?.applicationPath = "/fixture/App\(index).app"
            return rule
        }
        let bar = CommandBar(model: model, fileScopes: [root], captureTarget: { nil }, loadIcon: { _ in NSImage(size: NSSize(width: 24, height: 24)) }, loadApplications: { apps })
        defer { bar.stop() }
        let cold = ContinuousClock.now
        bar.show()
        for _ in 0..<100 where !bar.results.contains(where: { $0.id.hasPrefix("app:") }) { try await Task.sleep(for: .milliseconds(5)) }
        print("Synthetic command cold open/index: \(cold.duration(to: .now))")
        bar.hide()
        let warm = ContinuousClock.now
        bar.show()
        print("Synthetic command warm open: \(warm.duration(to: .now))")
        let queries = ContinuousClock.now
        for _ in 0..<10 {
            for query in ["Synthetic", "Synthetic App 19", "Synthetic App 1999", ""] { bar.query = query }
        }
        print("Synthetic command 40 query changes: \(queries.duration(to: .now))")
        bar.query = "Synthetic App"
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Frog command bar" && $0.isVisible })
        panel.contentView?.layoutSubtreeIfNeeded()
        let scroll = ContinuousClock.now
        for _ in 0..<79 {
            try send(125, to: panel)
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        print("Synthetic command 79 keyboard scroll/layout steps: \(scroll.duration(to: .now))")
        XCTAssertEqual(bar.selection, 79)
        XCTAssertEqual(bar.results.count, 80)
    }

    func testSpotlightSetupPersistsFrogShortcutWithoutChangingRules() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = Configuration()
        try ConfigurationStore(directory: root).save(config)
        let model = AppModel(dataDirectory: root, registerShortcuts: false)
        defer { model.shutdown() }
        let previousRules = model.configuration.rules
        try model.useCommandBarShortcut(Hotkey(keyCode: 49, modifiers: 256))
        try model.useCommandBarShortcut(Hotkey(keyCode: 49, modifiers: 256))
        let saved = try ConfigurationStore(directory: root).load()
        XCTAssertTrue(saved.preferences.featureEnabled(.commandBar))
        XCTAssertEqual(saved.preferences.toolkitSettings.effectiveCommandBarHotkey, Hotkey(keyCode: 49, modifiers: 256))
        XCTAssertEqual(saved.rules, previousRules)
        XCTAssertEqual(saved.providers, model.configuration.providers)
    }

    func testWarmCatalogueIsImmediateWhileRefreshWaitsAndPanelRetainsMovedPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.preferences.setFeature(.commandBar, enabled: true)
        config.preferences.windowSwitcherEnabled = false
        try ConfigurationStore(directory: root).save(config)
        let model = AppModel(dataDirectory: root, registerShortcuts: false)
        defer { model.shutdown() }
        let gate = CommandIndexGate()
        var loads = 0
        let apps = (0..<2000).map { index in
            var rule = Rule(name: "Sample App \(index)"); rule.action = RuleAction(category: .application)
            rule.action?.applicationPath = "/fixture/App\(index).app"
            return rule
        }
        let bar = CommandBar(model: model, fileScopes: [root], captureTarget: { nil }, loadApplications: {
            loads += 1
            if loads == 1 { return apps }
            return await gate.wait()
        })
        defer { bar.stop() }
        bar.warm()
        for _ in 0..<100 where loads == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await Task.yield()
        let start = ContinuousClock.now
        bar.show()
        XCTAssertTrue(bar.results.contains { $0.id.hasPrefix("feature:") }, "Start view mixes useful actions with apps")
        XCTAssertTrue(bar.results.contains { $0.id.hasPrefix("app:") })
        bar.query = "Sample App 1999"
        XCTAssertEqual(bar.results.first?.title, "Sample App 1999", "Cached results must not wait for application refresh")
        print("Command bar warm open + 2,000-app search: \(start.duration(to: .now))")
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Frog command bar" && $0.isVisible })
        let visible = try XCTUnwrap(panel.screen?.visibleFrame)
        let moved = NSPoint(x: visible.minX + 35, y: visible.minY + 45)
        panel.setFrameOrigin(moved)
        await gate.started()
        bar.hide(); await gate.release()
        await Task.yield()
        bar.show()
        XCTAssertEqual(panel.frame.origin, moved)
        bar.finishDragging()
        XCTAssertTrue(bar.showsPositionReset)
        bar.center()
        XCTAssertFalse(bar.showsPositionReset)
        XCTAssertEqual(panel.frame.midX, visible.midX, accuracy: 1)
        XCTAssertEqual(panel.frame.midY, visible.midY, accuracy: 1)
        bar.query = "25% * 200"
        XCTAssertEqual(bar.results.first?.title, "50")
        await gate.started()
        bar.hide(); await gate.release()
    }

    func testResultIconsLoadOffMainThreadAndSuccessfulActionsBecomeSuggestions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = Configuration()
        configuration.preferences.setFeature(.commandBar, enabled: true)
        configuration.preferences.setFeature(.quickActions, enabled: true)
        configuration.preferences.windowSwitcherEnabled = false
        try ConfigurationStore(directory: root).save(configuration)
        let model = AppModel(dataDirectory: root, registerShortcuts: false)
        defer { model.shutdown() }
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let bar = CommandBar(model: model, pasteboard: pasteboard, fileScopes: [root], captureTarget: { nil }, waitForRelease: {}, loadIcon: { _ in
            XCTAssertFalse(Thread.isMainThread, "Scrolling must never block on NSWorkspace icon reads")
            return NSImage(size: NSSize(width: 24, height: 24))
        }, loadApplications: { [] })
        defer { bar.stop() }
        let icon = await bar.icon(for: SearchRecord(id: "app:/fixture/Sample.app", title: "Sample", symbol: "app"))
        XCTAssertNotNil(icon)
        bar.show(); bar.query = "Generate UUID"
        let choice = try XCTUnwrap(bar.results.firstIndex { $0.id == "quick:uuid" })
        bar.choose(choice)
        for _ in 0..<100 where pasteboard.string(forType: .string) == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(pasteboard.string(forType: .string).flatMap(UUID.init(uuidString:)))
        bar.show()
        XCTAssertEqual(bar.results.first?.id, "quick:uuid")
    }

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
    func release(_ rules: [Rule]? = nil) {
        var rule = Rule(name: "Late app"); rule.action = RuleAction(category: .application)
        rule.action?.applicationPath = "/fixture/Late.app"
        waiting?.resume(returning: rules ?? [rule]); waiting = nil
    }
}

@MainActor private final class CommandFileFixture: CommandFileSearching {
    struct Request {
        let text: String
        let receive: @MainActor ([SearchRecord]) -> Void
    }
    var requests: [Request] = []
    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void) {
        requests.append(Request(text: text, receive: receive))
    }
    func stop() {}
    /// A typed query starts its search on the bar's own debounce; wait for it rather than racing that timer.
    func request(_ text: String) async throws -> Request {
        for _ in 0..<600 where requests.last?.text != text { try await Task.sleep(for: .milliseconds(5)) }
        return try XCTUnwrap(requests.last.flatMap { $0.text == text ? $0 : nil }, "No file search started for \(text)")
    }
}

private final class CommandIconFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0
    let release = DispatchSemaphore(value: 0)
    var count: Int { lock.lock(); defer { lock.unlock() }; return loads }
    func load(_ path: String) -> NSImage {
        XCTAssertFalse(Thread.isMainThread)
        lock.lock(); loads += 1; lock.unlock()
        _ = release.wait(timeout: .now() + 2)
        return NSImage(size: NSSize(width: 24, height: 24))
    }
}
