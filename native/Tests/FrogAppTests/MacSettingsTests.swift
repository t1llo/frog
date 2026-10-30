import AppKit
import XCTest
import FrogCore
@testable import FrogApp

@MainActor final class MacSettingsTests: XCTestCase {
    func testInstalledSystemCatalogueAndWarmMixedQueryTiming() async throws {
        let start = ContinuousClock.now
        let settings = await Task.detached { MacSettingsDiscovery.scan() }.value
        print("System settings background discovery: \(settings.count) destinations, \(start.duration(to: .now))")
        let apps = (0..<2000).map { SearchRecord(id: "app:\($0)", title: "Synthetic App \($0)") }
        let records = apps + settings.map(\.record)
        let queryStart = ContinuousClock.now
        for _ in 0..<10 {
            for query in ["Synthetic App 1999", "change desktop background", "wifi", "audio"] {
                XCTAssertFalse(CommandSearch.results(records, query: query).isEmpty)
            }
        }
        print("System settings + 2,000 synthetic apps, 40 mixed queries: \(queryStart.duration(to: .now))")
        XCTAssertEqual(CommandSearch.results(records, query: "change desktop background").first?.title, "Wallpaper")
        XCTAssertEqual(CommandSearch.results(records, query: "do not disturb").first?.title, "Focus")
        let wallpaper = try XCTUnwrap(settings.first { $0.record.title == "Wallpaper" })
        XCTAssertNotNil(NSWorkspace.shared.urlForApplication(toOpen: try XCTUnwrap(wallpaper.destinations.first)), "Verify the native URL handler without opening Settings")
    }

    func testSettingsAreImmediateWithoutOtherFeaturesOrCompletedDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration()
        for feature in FeatureID.allCases { config.preferences.setFeature(feature, enabled: feature == .commandBar) }
        config.preferences.windowSwitcherEnabled = false
        try ConfigurationStore(directory: root).save(config)
        let model = AppModel(dataDirectory: root, registerShortcuts: false)
        defer { model.shutdown() }
        let gate = SettingsDiscoveryGate()
        var opened: SystemSetting?
        let bar = CommandBar(model: model, fileScopes: [root], captureTarget: { nil }, waitForRelease: {},
                             loadSettings: { await gate.wait() }, openSetting: { opened = $0 }, loadApplications: { [] })
        defer { bar.stop() }
        bar.show()
        bar.query = "change my desktop wallpaper"
        XCTAssertEqual(bar.results.first?.title, "Wallpaper")
        await gate.started()
        bar.choose()
        for _ in 0..<100 where opened == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(opened?.destinations.first?.absoluteString, "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")
        await gate.release()
        await Task.yield()
        XCTAssertTrue(bar.results.isEmpty, "Finishing discovery cannot reopen a dismissed command bar")
    }

    func testEachSettingsPaneAppearsOnceWithNoMacActionLabelAndAPaneWithoutAnIconLooksLikeSystemSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration()
        for feature in FeatureID.allCases { config.preferences.setFeature(feature, enabled: feature == .commandBar || feature == .applicationShortcuts) }
        config.preferences.windowSwitcherEnabled = false
        try ConfigurationStore(directory: root).save(config)
        let model = AppModel(dataDirectory: root, registerShortcuts: false)
        defer { model.shutdown() }
        let iconPaths = SettingsIconPaths()
        let bar = CommandBar(model: model, fileScopes: [root], captureTarget: { nil }, waitForRelease: {},
                             loadIcon: { iconPaths.append($0); return NSImage(size: NSSize(width: 16, height: 16)) },
                             loadSettings: { SystemSettingsCatalog.defaults }, loadApplications: { [] })
        defer { bar.stop() }
        // Mac commands come from the Shortcuts plugin.
        await model.pluginHost.syncAndWait()
        bar.show()
        for query in ["display", "displays", "display settings", "wifi", "bluetooth", "sound", "keyboard", "trackpad", "accessibility", "notifications", "storage", "privacy"] {
            bar.query = query
            print("Settings query \(query): \(bar.results.prefix(4).map { "\($0.title) · \($0.subtitle)" })")
            XCTAssertEqual(bar.results.first?.subtitle, "System Settings", query)
            XCTAssertFalse(bar.results.contains { $0.id.hasPrefix("system:") && $0.title.localizedCaseInsensitiveContains("settings") }, "\(query): one pane, one result")
        }
        bar.query = "display"
        let displays = try XCTUnwrap(bar.results.first)
        XCTAssertEqual(displays.title, "Displays")
        _ = await bar.icon(for: displays)
        XCTAssertEqual(iconPaths.values, ["/System/Applications/System Settings.app"], "A pane without an icon of its own looks like System Settings")
        bar.query = ""
        XCTAssertFalse(bar.results.contains { $0.subtitle == "Mac action" })
        for (query, title, label) in [("lock", "Lock screen", "Mac"), ("downloads", "Open Downloads folder", "Finder"), ("undo", "Undo", "Current app")] {
            bar.query = query
            let result = try XCTUnwrap(bar.results.first { $0.title == title }, query)
            XCTAssertEqual(result.subtitle, label)
        }
        // Every hidden shortcut action has its pane in the catalogue, so nothing became unreachable.
        let panes = Set(SystemSettingsCatalog.defaults.filter { $0.anchor == nil }.map(\.paneID))
        for action in SystemAction.allCases {
            guard let url = SystemActionController.destination(for: action), url.scheme == "x-apple.systempreferences" else { continue }
            let pane = String(url.absoluteString.dropFirst("x-apple.systempreferences:".count))
            XCTAssertTrue(pane.isEmpty || panes.contains(pane), "\(action.title) has no catalogue pane")
        }
    }

    func testDiscoveryRunsOffMainThreadAndIsCachedAcrossConcurrentLoads() async {
        let calls = SettingsDiscoveryCounter()
        let index = MacSettingsIndex(discover: {
            XCTAssertFalse(Thread.isMainThread)
            calls.increment()
            return SystemSettingsCatalog.defaults
        })
        async let first = index.load()
        async let second = index.load()
        let (a, b) = await (first, second)
        let third = await index.load()
        XCTAssertEqual(a, b); XCTAssertEqual(a, third)
        XCTAssertEqual(calls.count, 1)
    }

    func testInstalledPaneDiscoveryUsesLocalizedTermsAndExcludesUnopenableExtensions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func bundle(_ name: String, id: String, openable: Bool) throws {
            let contents = root.appendingPathComponent(name + ".appex/Contents")
            let language = contents.appendingPathComponent("Resources/en.lproj")
            try FileManager.default.createDirectory(at: language, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleDisplayName": name,
                "CFBundlePackageType": "XPC!", "EXAppExtensionAttributes": ["SettingsExtensionAttributes": ["allowsXAppleSystemPreferencesURLScheme": openable]]]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            let terms: [String: Any] = ["SyntheticGroup": ["localizableStrings": [["title": "Synthetic calibration", "index": "fixture tuning, synthetic colors"]]]]
            try PropertyListSerialization.data(fromPropertyList: terms, format: .xml, options: 0).write(to: language.appendingPathComponent("Pane.searchTerms"))
        }
        try bundle("Fixture Display", id: "com.apple.FixtureDisplay", openable: true)
        try bundle("Fixture Widget", id: "com.apple.FixtureWidget", openable: false)
        let found = await Task.detached { MacSettingsDiscovery.scan(root: root, legacyRoot: root, languages: ["en"]) }.value
        XCTAssertTrue(found.contains { $0.paneID == "com.apple.FixtureDisplay" })
        XCTAssertFalse(found.contains { $0.paneID == "com.apple.FixtureWidget" })
        XCTAssertEqual(CommandSearch.results(found.map(\.record), query: "fixture tuning").first?.title, "Fixture Display")
        XCTAssertEqual(CommandSearch.results(found.map(\.record), query: "wallpaper").first?.title, "Wallpaper")
    }

    func testSettingsNavigationFallsBackOnlyWhenTheNativeOpenFails() throws {
        let setting = try XCTUnwrap(SystemSettingsCatalog.defaults.first { $0.record.title == "Wallpaper" })
        var attempts: [URL] = []
        try MacSettingsNavigation.open(setting) { url in attempts.append(url); return attempts.count == 2 }
        XCTAssertEqual(attempts, Array(setting.destinations.prefix(2)))
        attempts = []
        try MacSettingsNavigation.open(setting) { url in attempts.append(url); return url.isFileURL }
        XCTAssertEqual(attempts.last?.lastPathComponent, "System Settings.app")
        XCTAssertThrowsError(try MacSettingsNavigation.open(setting, using: { _ in false }))
    }
}

private actor SettingsDiscoveryGate {
    private var pending: CheckedContinuation<[SystemSetting], Never>?
    private var start: CheckedContinuation<Void, Never>?
    func wait() async -> [SystemSetting] {
        await withCheckedContinuation { pending = $0; start?.resume(); start = nil }
    }
    func started() async { if pending == nil { await withCheckedContinuation { start = $0 } } }
    func release() { pending?.resume(returning: SystemSettingsCatalog.defaults); pending = nil }
}

private final class SettingsIconPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    func append(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
}

private final class SettingsDiscoveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
