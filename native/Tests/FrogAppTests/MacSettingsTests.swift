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

private final class SettingsDiscoveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
