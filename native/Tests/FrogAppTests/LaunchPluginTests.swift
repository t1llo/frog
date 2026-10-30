import AppKit
import SwiftUI
import XCTest
import FrogCore
@testable import FrogApp

/// The Command bar and Shortcuts plugins: their config.toml tables, their actions, and an action that asks for a
/// value in the bar. Models register no global shortcuts.
@MainActor final class LaunchPluginTests: XCTestCase {
    private var root: URL!
    private var pasteboard: NSPasteboard!
    private var model: AppModel?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        pasteboard = NSPasteboard(name: .init(UUID().uuidString))
    }

    override func tearDown() async throws {
        model?.shutdown(); model = nil
        pasteboard.releaseGlobally(); pasteboard = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func start(_ configure: (inout Configuration) -> Void = { _ in }) async throws -> AppModel {
        var config = Configuration(); config.preferences.windowSwitcherEnabled = false
        for feature in [FeatureID.commandBar, .applicationShortcuts] { config.preferences.setFeature(feature, enabled: true) }
        configure(&config)
        try ConfigurationStore(directory: root).save(config)
        let model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil },
                             clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard))
        self.model = model
        await model.pluginHost.syncAndWait()
        return model
    }

    private func configText() throws -> String { try String(contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8) }

    private func listed(_ model: AppModel) async throws -> [[String: Any]] {
        let result = try await model.pluginHost.run("shortcuts.list", ActionInput(source: .agent))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [[String: Any]])
    }

    func testAppAndMacCommandShortcutsMoveToTheirTableOnceAndBindAnyAction() async throws {
        let model = try await start { config in
            var app = Rule(name: "Open Notes", hotkey: Hotkey(keyCode: 45, modifiers: 256 | 2048))
            app.action = RuleAction(category: .application)
            app.action?.applicationBundleID = "com.example.notes"; app.action?.applicationPath = "/Applications/Fixture Notes.app"
            var lock = Rule(name: "Lock", hotkey: Hotkey(keyCode: 37, modifiers: 4096 | 2048))
            lock.action = RuleAction(category: .system); lock.action?.systemAction = .lockScreen
            config.rules = [app, lock]
        }
        let seeded = try await listed(model)
        XCTAssertEqual(seeded.map { $0["action"] as? String }, ["shortcuts.open-app", "shortcuts.system"])
        XCTAssertEqual(seeded.map { $0["key"] as? String }, ["alt+cmd+n", "ctrl+alt+l"].map { try? Shortcut($0).description })
        XCTAssertEqual(seeded[0]["with"] as? [String: String], ["app": "com.example.notes", "path": "/Applications/Fixture Notes.app"],
                       "The path tells apart copies that share the bundle ID")
        XCTAssertEqual(seeded[1]["title"] as? String, "Lock screen")
        XCTAssertTrue(try configText().contains("[shortcuts]"))
        XCTAssertFalse(AppModel.hotkeyRules(for: model.configuration).contains { $0.name == "Open Notes" }, "Only the plugin registers them")

        // Any action that runs from a shortcut can be bound; one key runs one thing.
        let bind = { (key: String, action: String, with: String?) in
            var values = ["key": key, "action": action]; values["with"] = with
            return try await model.pluginHost.run("shortcuts.bind", ActionInput(values: values, source: .agent))
        }
        _ = try await bind("ctrl+alt+k", "command-bar.show", nil)
        _ = try await bind("ctrl+alt+l", "shortcuts.open-app", "app=Safari")
        var bindings = try await listed(model)
        XCTAssertEqual(bindings.count, 3)
        XCTAssertEqual(bindings.last?["action"] as? String, "shortcuts.open-app")
        XCTAssertFalse(bindings.contains { $0["action"] as? String == "shortcuts.system" }, "The key's earlier binding is replaced")
        for (key, action, with, message) in [("ctrl+alt+x", "nothing.here", nil, "unknown"), ("ctrl+alt+x", "shortcuts.open-app", nil, "missing"),
                                             ("ctrl+alt+x", "command-bar.search", "query=a", "agent only"), ("banana", "command-bar.show", nil, "key"),
                                             ("ctrl+alt+x", "shortcuts.system", "command=nothing", "not a choice"),
                                             ("ctrl+alt+space", "command-bar.show", nil, "the command bar's own key")] as [(String, String, String?, String)] {
            do { _ = try await bind(key, action, with); XCTFail(message) } catch {}
        }

        _ = try await model.pluginHost.run("shortcuts.unbind", ActionInput(values: ["key": "ctrl+alt+k"], source: .agent))
        bindings = try await listed(model)
        XCTAssertEqual(bindings.count, 2)

        // The table is the truth from now on: the rules are not read again, and an edit in the file is followed.
        let store = ConfigStore(fileURL: root.appendingPathComponent("config.toml"))
        try store.load()
        XCTAssertEqual(try store.section("shortcuts", as: ShortcutsSettings.self).value.bindings?.count, 2)
        try await model.pluginHost.setEnabled("shortcuts", false)
        try await model.pluginHost.setEnabled("shortcuts", true)
        await model.pluginHost.syncAndWait()
        let reloaded = try await listed(model)
        XCTAssertEqual(reloaded.count, 2)
    }

    func testAShortcutsTableThatCannotBeReadIsKeptAndAKeyMovesBetweenBindings() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "[shortcuts]\nbindings = \"not a list\"\n".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let model = try await start()
        let plugin = try XCTUnwrap(model.pluginHost.running["shortcuts"] as? ShortcutsPlugin)
        XCTAssertNotNil(plugin.unreadable)
        XCTAssertEqual(plugin.bindings, [], "Nothing is seeded over a table that is there")
        XCTAssertTrue(try configText().contains("not a list"), "The table is left for the user to repair")

        // Repaired: the bindings come back. A disabled old rule is kept without its key.
        var off = ShortcutBinding(key: nil, action: ShortcutBinding.system, with: ["command": "lockScreen"])
        let first = ShortcutBinding(key: try Shortcut("ctrl+alt+1"), action: "command-bar.show")
        try plugin.save([first, off])
        XCTAssertNil(plugin.unreadable)
        XCTAssertEqual(model.pluginShortcuts.filter { $0.key != CommandBarPlugin.shortcutID }.values.map(\.name), ["Open the command bar"])

        // A key another binding had moves to the edited one; neither binding is lost.
        try plugin.setKey(try Shortcut("ctrl+alt+2"), at: 1)
        try plugin.setKey(try Shortcut("ctrl+alt+2"), at: 0)
        off.key = nil
        XCTAssertEqual(plugin.bindings.map(\.key), [try Shortcut("ctrl+alt+2"), nil])
        XCTAssertEqual(plugin.bindings.count, 2)
        // A key that something else in Frog answers to is refused.
        XCTAssertThrowsError(try plugin.setKey(CommandBarSettings.defaultShortcut, at: 1))
        XCTAssertEqual(model.shortcutOwner(of: try Shortcut("ctrl+alt+2").hotkey), "Open the command bar")
        XCTAssertTrue(model.unmirroredPluginShortcuts.contains { $0.hotkey == (try? Shortcut("ctrl+alt+2"))?.hotkey },
                      "The window switcher's conflict check sees the bindings")

        // A key saved while a shortcut is being recorded is the one registered once recording ends.
        let recorder = UUID()
        model.beginShortcutRecording(recorder)
        try plugin.setKey(try Shortcut("ctrl+alt+3"), at: 0)
        model.endShortcutRecording(recorder)
        XCTAssertEqual(model.pluginShortcuts.filter { $0.key != CommandBarPlugin.shortcutID }.values.map(\.hotkey), [try Shortcut("ctrl+alt+3").hotkey])
    }

    func testSeedsAreSkippedWhileTheSettingsCannotBeLoaded() async throws {
        var config = Configuration(); config.preferences.windowSwitcherEnabled = false
        try ConfigurationStore(directory: root).save(config)
        for name in ["config", "config.json"] where FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            try "{ not valid".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil },
                             clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard))
        self.model = model
        await model.pluginHost.syncAndWait()
        XCTAssertFalse(model.configurationLoaded)
        let text = (try? configText()) ?? ""
        XCTAssertFalse(text.contains("[shortcuts]"), text)
        XCTAssertFalse(text.contains("[command-bar]"), text)
    }

    func testABrokenCommandBarTableIsKeptAndOldStyleWritesReachTheTable() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "[command-bar]\nshortcut = \"banana\"\n".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let model = try await start { config in
            config.preferences.ensureToolkit(); config.preferences.toolkit?.commandBarHotkey = Hotkey(keyCode: 49, modifiers: 256)
        }
        let plugin = try XCTUnwrap(model.pluginHost.running["command-bar"] as? CommandBarPlugin)
        XCTAssertNotNil(plugin.unreadable)
        XCTAssertEqual(plugin.settings.shortcut.description, "cmd+space", "The shortcut the bar last mirrored")
        XCTAssertEqual(model.configuration.preferences.toolkitSettings.effectiveCommandBarHotkey, Hotkey(keyCode: 49, modifiers: 256))
        XCTAssertTrue(try configText().contains("banana"))

        plugin.save { $0.shortcut = try! Shortcut("ctrl+alt+b") }
        XCTAssertNil(plugin.unreadable)
        // `frog config set shortcut.command-bar` and imports write the old preferences; the table follows.
        try model.updateToolkit { $0.commandBarHotkey = try! Shortcut("ctrl+alt+c").hotkey }
        XCTAssertEqual(plugin.settings.shortcut.description, try Shortcut("ctrl+alt+c").description)
        XCTAssertEqual(try ConfigStore.loaded(root).section("command-bar", as: CommandBarSettings.self).value.shortcut, plugin.settings.shortcut)
        XCTAssertEqual(model.pluginShortcuts[CommandBarPlugin.shortcutID]?.hotkey, try Shortcut("ctrl+alt+c").hotkey)

        // ⌘Space setup turns the plugin on in config.toml too.
        try await model.pluginHost.setEnabled("command-bar", false)
        try model.useCommandBarShortcut(Hotkey(keyCode: 49, modifiers: 256))
        await model.pluginHost.syncAndWait()
        XCTAssertEqual(try ConfigStore.loaded(root).pluginSwitches()["command-bar"], true)
        XCTAssertEqual((model.pluginHost.running["command-bar"] as? CommandBarPlugin)?.settings.shortcut.description, "cmd+space")
    }

    func testCommandBarTableSeedsFromThePreferencesAndSearchReturnsTheRankedRows() async throws {
        let model = try await start { config in
            config.preferences.ensureToolkit()
            config.preferences.toolkit?.commandBarHotkey = Hotkey(keyCode: 49, modifiers: 256)
            config.preferences.toolkit?.commandBar = { var bar = CommandBarPreferences(); bar.learnChoices = true; return bar }()
        }
        let plugin = try XCTUnwrap(model.pluginHost.running["command-bar"] as? CommandBarPlugin)
        XCTAssertEqual(plugin.settings.shortcut.description, "cmd+space")
        XCTAssertTrue(plugin.settings.learnChoices)
        let text = try configText()
        XCTAssertTrue(text.contains("[command-bar]"))
        XCTAssertTrue(text.contains("learn-choices = true"))

        plugin.save { $0.learnChoices = false }
        XCTAssertFalse(model.configuration.preferences.toolkitSettings.commandBarSettings.learnChoices, "The preferences follow the table")

        let clock = ContinuousClock(), started = clock.now
        let result = try await model.pluginHost.run("command-bar.search", ActionInput(values: ["query": "lock screen", "limit": "5"], source: .agent))
        print("command-bar.search took \(clock.now - started), apps included")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [[String: String]])
        XCTAssertLessThanOrEqual(rows.count, 5)
        XCTAssertTrue(rows.contains { $0["id"] == "system:lockScreen" }, "\(rows)")
        do { _ = try await model.pluginHost.run("command-bar.search", ActionInput(source: .agent)); XCTFail("A query is required") } catch {}
    }

    func testAnActionWithOneParameterAsksForItInTheBar() async throws {
        let model = try await start()
        var received: [String] = []
        let action = PluginAction(id: "fixture.greet", title: "Greet fixture", parameters: [ActionParameter(name: "who", kind: .choice(["alpha", "beta"]), required: true)],
                                  surfaces: [.commandBar]) { input in received.append(try input.required("who")); return .done() }
        let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, waitForRelease: {}, fileSearch: NoCommandFileSearch(),
                             loadSettings: { [] }, loadApplications: { [] }, extraProviders: [PluginActionRows(actions: { _ in [action] })])
        defer { bar.stop() }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "greet fix"
        let index = try XCTUnwrap(bar.results.firstIndex { $0.id == "action:fixture.greet" })
        bar.choose(index)
        XCTAssertEqual(bar.argument?.title, "Greet fixture")
        XCTAssertEqual(bar.query, "", "The field takes the value")
        XCTAssertEqual(bar.results.map(\.title), ["alpha", "beta"])
        bar.query = "be"
        XCTAssertEqual(bar.results.map(\.title), ["beta"])
        bar.leaveArgument()
        XCTAssertNil(bar.argument)
        XCTAssertEqual(bar.query, "greet fix", "Going back restores what was typed")

        bar.choose(try XCTUnwrap(bar.results.firstIndex { $0.id == "action:fixture.greet" }))
        bar.query = "be"
        bar.choose(0)
        for _ in 0..<200 where received.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(received, ["beta"])
    }

    func testTheBarOpensInOneStepAndReportsHowLongItTook() async throws {
        let model = try await start()
        let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, waitForRelease: {}, fileSearch: NoCommandFileSearch(),
                             loadSettings: { SystemSettingsCatalog.defaults }, loadApplications: { [] })
        defer { bar.stop() }
        var opens: [(rows: Duration, shown: Duration)] = []
        for _ in 0..<5 {
            bar.show()
            opens.append(try XCTUnwrap(bar.lastOpen))
            bar.hide()
        }
        // The first open builds the panel; the rest reuse it.
        let later = opens.dropFirst()
        print("Command bar open: first \(opens[0].shown) (rows \(opens[0].rows)), then at most \(later.map(\.shown).max()!) (rows \(later.map(\.rows).max()!))")
        let clock = ContinuousClock()
        bar.show()
        var slowest = Duration.zero
        for query in ["s", "sa", "saf", "safa", "lock", "lock s", "display"] {
            slowest = max(slowest, clock.measure { bar.query = query })
        }
        bar.hide()
        print("Command bar keystroke: slowest \(slowest)")
    }

    /// `shortcuts-filled-light.png` and `-dark.png` in `FROG_PAGE_SHOTS`: the Shortcuts page with bindings.
    func testShortcutsPageWithBindingsShot() async throws {
        guard let folder = ProcessInfo.processInfo.environment["FROG_PAGE_SHOTS"] else { throw XCTSkip("Set FROG_PAGE_SHOTS to take it") }
        let model = try await start { config in
            var app = Rule(name: "Finder", hotkey: Hotkey(keyCode: 3, modifiers: 4096 | 2048))
            app.action = RuleAction(category: .application)
            app.action?.applicationBundleID = "com.apple.finder"; app.action?.applicationPath = "/System/Library/CoreServices/Finder.app"
            var lock = Rule(name: "Lock", hotkey: Hotkey(keyCode: 37, modifiers: 4096 | 2048))
            lock.action = RuleAction(category: .system); lock.action?.systemAction = .lockScreen
            config.rules = [app, lock]
        }
        let plugin = try XCTUnwrap(model.pluginHost.running["shortcuts"] as? ShortcutsPlugin)
        try plugin.bind(try Shortcut("ctrl+alt+space"), to: "command-bar.show")
        try plugin.save(plugin.bindings + [ShortcutBinding(key: nil, action: ShortcutBinding.openApp, with: ["app": "com.apple.Safari"])])
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: ShortcutsSettingsView(plugin: plugin).environmentObject(model).frame(width: 760, height: 520)
                .background(FrogStyle.opaqueCanvas))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "\(folder)/shortcuts-filled-\(appearance == .aqua ? "light" : "dark").png"))
        }
    }
}

private extension ConfigStore {
    static func loaded(_ root: URL) throws -> ConfigStore {
        let store = ConfigStore(fileURL: root.appendingPathComponent("config.toml"))
        try store.load()
        return store
    }
}
