import AppKit
import Darwin
import FrogCore
import XCTest
@testable import FrogApp

/// The Clipboard plugin: its switch, its config.toml table, and its actions run as `frog run` runs them.
@MainActor
final class ClipboardPluginTests: XCTestCase {
    private var directory: URL!
    private var pasteboard: NSPasteboard!
    private var history: ClipboardHistoryStore!
    private var model: AppModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-clipboard-plugin-\(UUID().uuidString)", isDirectory: true)
        try ConfigurationStore(directory: directory).save(Configuration())
        pasteboard = NSPasteboard.withUniqueName()
        history = ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate())
        model = AppModel(dataDirectory: directory, registerShortcuts: false, complete: { text, _, _, _ in text }, readKey: { _ in nil },
                         writeClipboard: { _ in }, clipboardHistoryStore: history)
        model.start()
        await model.pluginHost.syncAndWait()
        try await model.pluginHost.setEnabled("clipboard", true)
    }

    override func tearDown() async throws {
        await model.pluginHost.stopAll()
        model.shutdown()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    private var plugin: ClipboardPlugin? { model.pluginHost.running["clipboard"] as? ClipboardPlugin }

    private func run(_ id: String, _ values: [String: String] = [:]) async throws -> ActionResult {
        try await model.pluginHost.run(id, ActionInput(values: values, source: .agent))
    }

    func testOnKeepsCopiesAndOffForgetsThem() async throws {
        XCTAssertNotNil(plugin?.controller)
        XCTAssertTrue(history.enabled)
        XCTAssertEqual(model.settingsFile.document.value(at: ["clipboard", "shortcut"]), .string("shift+cmd+v"))
        XCTAssertEqual(plugin?.state.settings.shortcut.hotkey, Hotkey(keyCode: 9, modifiers: 768))
        XCTAssertEqual(model.settingsFile.document.value(at: ["clipboard", "items"]), .integer(ClipboardHistoryStore.defaultCapacity))
        history.recordCopiedText("Fixture kept")
        history.recordCopiedText("Tr0ub4dor&3")
        XCTAssertEqual(history.entries.map(\.text), ["Fixture kept"], "Passwords are never kept")

        plugin?.setItems(50)
        XCTAssertEqual(history.capacity, 50)
        XCTAssertEqual(model.settingsFile.document.value(at: ["clipboard", "items"]), .integer(50))

        try await model.pluginHost.setEnabled("clipboard", false)
        XCTAssertNil(plugin)
        XCTAssertFalse(history.enabled)
        XCTAssertTrue(history.entries.isEmpty)
        do { _ = try await run("clipboard.list"); XCTFail("Clipboard is off") } catch ActionError.pluginOff {}
    }

    func testActions() async throws {
        for text in ["Fixture alpha one", "Fixture beta", "Fixture alpha two"] { history.recordCopiedText(text) }

        let list = try await run("clipboard.list", ["limit": "2"])
        let items = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(list.json.utf8)) as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["text"] as? String }, ["Fixture alpha two", "Fixture beta"])
        XCTAssertEqual(list.text.split(separator: "\n").count, 2)
        XCTAssertTrue(list.text.hasPrefix(history.entries[0].shortID), list.text)
        do { _ = try await run("clipboard.list", ["limit": "0"]); XCTFail("Limit out of range") } catch ActionError.invalid {}

        let found = try await run("clipboard.search", ["query": "ALPHA one"])
        XCTAssertTrue(found.text.hasSuffix("Fixture alpha one"), found.text)
        do { let text = try await run("clipboard.search", ["query": "gamma"]).text; XCTAssertEqual(text, "No copied text matches.") }

        let beta = history.entries[1]
        do { let text = try await run("clipboard.copy", ["id": beta.shortID]).text; XCTAssertEqual(text, "Copied.") }
        XCTAssertEqual(pasteboard.string(forType: .string), "Fixture beta")
        do { let text = try await run("clipboard.copy", ["id": beta.id.uuidString]).text; XCTAssertEqual(text, "Copied.") }
        do { _ = try await run("clipboard.paste", ["id": "ffffffff"]); XCTFail("Unknown item") } catch ActionError.failed {}

        do { let text = try await run("clipboard.clear").text; XCTAssertEqual(text, "Cleared.") }
        XCTAssertTrue(history.entries.isEmpty)
        do { let text = try await run("clipboard.list").text; XCTAssertEqual(text, "Nothing copied yet.") }
    }

    func testShortcutIsMirroredAndAClashIsRefused() async throws {
        let plugin = try XCTUnwrap(plugin)
        let mine = Hotkey(keyCode: 9, modifiers: 256 | 2048)
        plugin.setShortcut(mine)
        XCTAssertEqual(plugin.state.settings.shortcut.hotkey, mine)
        XCTAssertEqual(model.configuration.preferences.workflowSettings.clipboardHistoryHotkey, mine, "The preferences keep a copy")

        // Another Frog shortcut takes keys: the page cannot give them to the clipboard too.
        let taken = Hotkey(keyCode: 11, modifiers: 256 | 2048)
        var workflow = model.configuration.preferences.workflowSettings
        workflow.shortcutPanelHotkey = taken
        try model.saveWorkflowPreferences(workflow)
        plugin.setShortcut(taken)
        XCTAssertEqual(plugin.state.settings.shortcut.hotkey, mine, "A clashing shortcut is not saved")
        XCTAssertEqual(model.configuration.preferences.workflowSettings.clipboardHistoryHotkey, mine)

        // Written into config.toml by hand, it stays unregistered and the page says why.
        var edited = plugin.state.settings
        edited.shortcut = try Shortcut(taken)
        try model.settingsFile.update("clipboard", edited)
        plugin.settingsChanged()
        XCTAssertNotNil(plugin.state.shortcutIssue)
        XCTAssertEqual(model.configuration.preferences.workflowSettings.clipboardHistoryHotkey, mine)

        // Reload and Import follow the old key.
        let reloaded = Hotkey(keyCode: 9, modifiers: 256 | 4096)
        workflow = model.configuration.preferences.workflowSettings
        workflow.clipboardHistoryHotkey = reloaded
        try model.saveWorkflowPreferences(workflow)
        ClipboardPlugin.adoptLegacySettings(model)
        XCTAssertEqual(plugin.state.settings.shortcut.hotkey, reloaded)
        XCTAssertNil(plugin.state.shortcutIssue)
        XCTAssertEqual(model.settingsFile.document.value(at: ["clipboard", "items"]), .integer(ClipboardHistoryStore.defaultCapacity), "Items stay")
    }

    func testItemsOutOfRangeAreShownAsKept() throws {
        let plugin = try XCTUnwrap(plugin)
        var edited = plugin.state.settings
        edited.items = 5000
        try model.settingsFile.update("clipboard", edited)
        plugin.settingsChanged()
        XCTAssertEqual(plugin.state.settings.items, ClipboardHistoryStore.maxCapacity)
        XCTAssertEqual(history.capacity, ClipboardHistoryStore.maxCapacity)
    }

    func testAnAmbiguousIDAsksForMoreCharacters() async throws {
        history.recordCopiedText("Fixture short")
        do { _ = try await run("clipboard.copy", ["id": String(history.entries[0].shortID.prefix(2))]); XCTFail("Too short") } catch let ActionError.failed(message) {
            XCTAssertTrue(message.contains("at least 4"), message)
        }
        // A thousand IDs almost surely share a first four characters; another thousand if not.
        plugin?.setItems(ClipboardHistoryStore.maxCapacity)
        var shared: [ClipboardHistoryEntry] = []
        for round in 0..<5 where shared.count < 2 {
            for index in 0..<1000 { history.recordCopiedText("Fixture \(round) \(index)") }
            shared = Dictionary(grouping: history.entries) { String($0.shortID.prefix(4)) }.values.first { $0.count > 1 } ?? []
        }
        let pair = try XCTUnwrap(shared.count > 1 ? shared : nil)
        do { _ = try await run("clipboard.copy", ["id": String(pair[0].shortID.prefix(4))]); XCTFail("Ambiguous") } catch let ActionError.failed(message) {
            XCTAssertTrue(message.contains("matches several items"), message)
        }
        do { let text = try await run("clipboard.copy", ["id": pair[0].shortID]).text; XCTAssertEqual(text, "Copied.") }
        XCTAssertEqual(pasteboard.string(forType: .string), pair[0].text)
    }

    /// 1000 items of a few hundred characters each: what they cost to keep, and a search over all of them.
    func testThousandItemsMemoryAndSearch() throws {
        plugin?.setItems(ClipboardHistoryStore.maxCapacity)
        let before = Self.heapBytes()
        let recordStart = ContinuousClock.now
        let words = ["invoice", "meeting", "deploy", "kitchen", "Zürich", "release", "budget", "garden"]
        for index in 0..<1000 {
            let text = (0..<40).map { words[($0 * 7 + index) % words.count] }.joined(separator: " ") + " item \(index)"
            history.recordCopiedText(text)
        }
        XCTAssertEqual(history.entries.count, 1000)
        let recording = (ContinuousClock.now - recordStart) / 1000
        let kept = history.entries.reduce(0) { $0 + $1.bytes + $1.preview.utf8.count }
        let grown = Self.heapBytes() - before
        var results: [ClipboardHistoryEntry] = []
        let start = ContinuousClock.now
        for _ in 0..<20 { results = ClipboardSearch.filter(history.entries, query: "zurich item 99") }
        let perSearch = (ContinuousClock.now - start) / 20
        let controller = try XCTUnwrap(plugin?.controller)
        var opened: [Duration] = []
        let prepare = ContinuousClock.now
        controller.prepare()
        let prepared = ContinuousClock.now - prepare
        for _ in 0..<2 {
            let open = ContinuousClock.now
            controller.show()
            opened.append(ContinuousClock.now - open)
            controller.hide()
        }
        print("clipboard 1000 items: text \(kept / 1024) KB, heap growth \(grown / 1024) KB, search \(perSearch), "
              + "record \(recording) per copy, panel built in \(prepared), "
              + "then opens in \(opened[0]) and \(opened[1])")
        XCTAssertEqual(results.count, 19, "99, 199 … 899 and 990 … 999")
        XCTAssertLessThan(perSearch, .milliseconds(30))
    }

    private static func heapBytes() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }
}
