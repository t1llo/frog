import AppKit
import Combine
import XCTest
import FrogCore
@testable import FrogApp

/// Which icon a System Settings row shows, before and after discovery, decided without presenting the bar's panel.
@MainActor final class CommandBarSettingsIconTests: XCTestCase {
    private let displaysIcon = SystemSettingIcon.bundle(path: "/Fixture/DisplaysExt.appex")
    private let privacyIcon = SystemSettingIcon.bundle(path: "/Fixture/SecurityPrivacyExtension.appex")

    func testListedRowsSwitchToTheirPanesIconsWhereTheyAre() async throws {
        let (model, pasteboard, cleanup) = try makeModel()
        defer { cleanup() }
        let gate = PaneDiscoveryGate(discovered: discovered())
        let reads = PaneIconReads()
        let bar = makeBar(model, pasteboard, gate: gate, reads: reads)
        defer { bar.stop() }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "permissions"
        let permissions = bar.results.filter { $0.id.hasPrefix("mac-setting:\(privacyPane)?") }
        XCTAssertGreaterThan(permissions.count, 3)
        bar.selection = 2
        let listed = bar.results, chosen = bar.results[2].id
        for row in permissions { XCTAssertEqual(bar.iconPath(for: row), MacSettingsDiscovery.fallbackIconPath, row.title) }
        let generic = await bar.icon(for: permissions[0])
        XCTAssertNotNil(generic)
        XCTAssertEqual(reads.keys, [MacSettingsDiscovery.fallbackIconPath])

        var changes = 0
        let observation = bar.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        bar.refreshSettings()
        await gate.started()
        await gate.release()
        for _ in 0..<200 where bar.iconPath(for: permissions[0]) == MacSettingsDiscovery.fallbackIconPath {
            try await Task.sleep(for: .milliseconds(5))
        }
        // The permission rows are the same records as before, so only the icon keys can tell their rows to redraw.
        XCTAssertEqual(bar.results, listed)
        XCTAssertEqual(bar.results[bar.selection].id, chosen, "The selection stays on its row")
        XCTAssertGreaterThan(changes, 0)
        for row in permissions { XCTAssertEqual(bar.iconPath(for: row), privacyIcon.key, row.title) }
        let own = await bar.icon(for: permissions[1])
        XCTAssertNotNil(own)
        XCTAssertFalse(own === generic)
        XCTAssertTrue(bar.cachedIcon(for: permissions[0]) === own, "Every permission row shares the Privacy & Security icon")
        XCTAssertEqual(reads.keys, [MacSettingsDiscovery.fallbackIconPath, privacyIcon.key])

        // A pane whose record changed with discovery takes its icon as well.
        bar.query = "screen resolution"
        let displays = try XCTUnwrap(bar.results.first)
        XCTAssertEqual(displays.title, "Displays")
        XCTAssertEqual(bar.iconPath(for: displays), displaysIcon.key)
        XCTAssertNil(bar.iconPath(for: SearchRecord(id: "features", title: "Manage features")))
    }

    func testAPaneKeepsItsPlaceAboveAnEquallyGoodRowListedWhileDiscoveryRan() async throws {
        let (model, pasteboard, cleanup) = try makeModel([.clipboard])
        defer { cleanup() }
        let history = model.clipboardHistoryStore
        history.configure(enabled: true, automaticallyPoll: false)
        let gate = PaneDiscoveryGate(discovered: discovered())
        let bar = makeBar(model, pasteboard, gate: gate, reads: PaneIconReads())
        defer { bar.stop() }
        bar.prepareResults(model, frontPID: nil)
        bar.refreshSettings()
        await gate.started()
        // A copy made while the bar is open is listed after the rows it opened with, and ties with the pane's title.
        history.recordCopiedText("Displays")
        bar.query = "displays"
        let displays = "mac-setting:com.apple.Displays-Settings.extension"
        func pair() -> [String] { bar.results.filter { $0.title == "Displays" }.map(\.id) }
        let listed = pair()
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed.first, displays)
        let before = try XCTUnwrap(bar.results.first { $0.id == displays })
        bar.selection = try XCTUnwrap(bar.results.firstIndex { $0.id == listed.last })
        let chosen = bar.selection

        await gate.release()
        for _ in 0..<200 where bar.iconPath(for: before) != displaysIcon.key { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotEqual(bar.results.first { $0.id == displays }, before, "The row lists the discovered record")
        XCTAssertEqual(pair(), listed, "The pane stays above the copy that ties with it")
        XCTAssertEqual(bar.selection, chosen, "The selection stays on its row and that row on its line")
    }

    func testDiscoveryAfterTheBarClosedKeepsTheIconsForTheNextOpenUntilTheBarStops() async throws {
        let (model, pasteboard, cleanup) = try makeModel()
        defer { cleanup() }
        let gate = PaneDiscoveryGate(discovered: discovered())
        let bar = makeBar(model, pasteboard, gate: gate, reads: PaneIconReads())
        defer { bar.stop() }
        bar.prepareResults(model, frontPID: nil)
        bar.refreshSettings()
        await gate.started()
        bar.hide()
        await gate.release()
        let displays = try XCTUnwrap(SystemSettingsCatalog.defaults.first { $0.record.title == "Displays" }).record
        for _ in 0..<200 where bar.iconPath(for: displays) != displaysIcon.key { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(bar.iconPath(for: displays), displaysIcon.key)
        XCTAssertTrue(bar.results.isEmpty, "Finishing discovery lists nothing in a closed bar")

        bar.prepareResults(model, frontPID: nil)
        bar.query = "screen resolution"
        let listed = try XCTUnwrap(bar.results.first)
        XCTAssertEqual(listed.id, displays.id)
        XCTAssertNotEqual(listed, displays, "The next open lists the discovered record")
        let icon = await bar.icon(for: listed)
        XCTAssertTrue(bar.cachedIcon(for: listed) === icon)

        bar.stop()
        XCTAssertNil(bar.cachedIcon(for: listed))
        XCTAssertEqual(bar.iconPath(for: listed), MacSettingsDiscovery.fallbackIconPath)
    }

    func testDiscoveryReadsEachPanesIconAndFallsBackWhereItHasNone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func pane(_ name: String, id: String, _ extra: [String: Any] = [:], representations: [[String: Any]] = []) throws {
            let contents = root.appendingPathComponent(name + ".appex/Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "XPC!",
                "EXAppExtensionAttributes": ["SettingsExtensionAttributes": ["allowsXAppleSystemPreferencesURLScheme": true, "representations": representations]]]
            info.merge(extra) { _, new in new }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        }
        try pane("SecurityPrivacyExtension", id: privacyPane, ["CFBundleIcons": ["ISGraphicIconConfiguration": ["ISTypeIdentifier": "com.apple.graphic-icon.privacy"]]])
        // The first alternative names a type no Mac declares and is passed over.
        try pane("PowerPreferences", id: "com.apple.Battery-Settings.extension", ["CFBundleIconFile": "icon"], representations: [
            ["predicate": "powersource.battery == YES", "sidebar-iconUTTypeIdentifier": "com.example.frog-fixture.undeclared"],
            ["predicate": "powersource.battery == YES", "sidebar-iconUTTypeIdentifier": "public.folder"]])
        try pane("HeadphoneSettingsExtension", id: "com.apple.HeadphoneSettings", ["CFBundleIconFile": "icon"])
        try pane("FixturePane", id: "com.apple.FixturePane", ["CFBundleDisplayName": "Fixture Pane", "CFBundleIconName": "AppIcon"])
        let found = await Task.detached { MacSettingsDiscovery.scan(root: root, legacyRoot: root, languages: ["en"], facts: ["powersource.battery": true]) }.value
        func icon(_ paneID: String) -> SystemSettingIcon? { found.first { $0.paneID == paneID && $0.anchor == nil }?.icon }

        let privacy = found.filter { $0.paneID == privacyPane }
        XCTAssertGreaterThan(privacy.count, 10)
        for setting in privacy {
            guard case .bundle(let path) = setting.icon else { return XCTFail("\(setting.record.title) has no icon") }
            XCTAssertEqual((path as NSString).lastPathComponent, "SecurityPrivacyExtension.appex", setting.record.title)
        }
        XCTAssertEqual(icon("com.apple.Battery-Settings.extension"), .type(identifier: "public.folder"))
        XCTAssertNil(icon("com.apple.HeadphoneSettings"), "Only the placeholder: the System Settings icon")
        XCTAssertNil(icon("com.apple.Wallpaper-Settings.extension"), "A pane this Mac does not have keeps the System Settings icon")
        guard case .bundle(let path) = icon("com.apple.FixturePane") else { return XCTFail("The new pane has no icon") }
        XCTAssertEqual((path as NSString).lastPathComponent, "FixturePane.appex")
        XCTAssertEqual(found.first { $0.paneID == "com.apple.FixturePane" }?.record.title, "Fixture Pane")
    }

    func testAnIconTypeThisMacDoesNotDeclareDrawsTheSystemSettingsIcon() throws {
        let fallback = try XCTUnwrap(pixels(NSWorkspace.shared.icon(forFile: MacSettingsDiscovery.fallbackIconPath)))
        let undeclared = SystemSettingIcon.type(identifier: "com.example.frog-fixture.undeclared").key
        XCTAssertEqual(pixels(MacSettingsDiscovery.image(forIconKey: undeclared)), fallback)
        let folder = SystemSettingIcon.type(identifier: "public.folder").key
        XCTAssertEqual(pixels(MacSettingsDiscovery.image(forIconKey: folder)), pixels(NSWorkspace.shared.icon(for: .folder)))
        XCTAssertNotEqual(pixels(MacSettingsDiscovery.image(forIconKey: folder)), fallback)
    }

    // MARK: - Fixtures

    private let privacyPane = "com.apple.settings.PrivacySecurity.extension"

    /// The catalogue as discovery returns it: Displays with search terms and an icon, the privacy pane's rows with
    /// the pane's icon and no other change.
    private func discovered() -> [SystemSetting] {
        SystemSettingsCatalog.defaults.map { setting in
            switch setting.paneID {
            case "com.apple.Displays-Settings.extension": setting.includingSearchTerms("Arrangement", localizedTitle: "Displays").withIcon(displaysIcon)
            case privacyPane: setting.withIcon(privacyIcon)
            default: setting
            }
        }
    }

    private func makeModel(_ features: [FeatureID] = []) throws -> (AppModel, NSPasteboard, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var config = Configuration(); config.preferences.windowSwitcherEnabled = false
        for feature in [.commandBar] + features { config.preferences.setFeature(feature, enabled: true) }
        try ConfigurationStore(directory: root).save(config)
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        let model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil },
                             clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard))
        return (model, pasteboard, {
            model.shutdown(); pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        })
    }

    private func makeBar(_ model: AppModel, _ pasteboard: NSPasteboard, gate: PaneDiscoveryGate, reads: PaneIconReads) -> CommandBar {
        CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, loadIcon: { reads.load($0) }, fileSearch: PaneFileStub(),
                   loadSettings: { await gate.wait() }, loadApplications: { [] }, applicationNames: { _ in [] })
    }

    private func pixels(_ image: NSImage) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.bitmapData.map { Data(bytes: $0, count: 32 * 128) }
    }
}

private actor PaneDiscoveryGate {
    private let discovered: [SystemSetting]
    private var pending: CheckedContinuation<[SystemSetting], Never>?
    private var start: CheckedContinuation<Void, Never>?
    init(discovered: [SystemSetting]) { self.discovered = discovered }
    func wait() async -> [SystemSetting] {
        await withCheckedContinuation { pending = $0; start?.resume(); start = nil }
    }
    func started() async { if pending == nil { await withCheckedContinuation { start = $0 } } }
    func release() { pending?.resume(returning: discovered); pending = nil }
}

/// Each icon key the bar reads, in order. Every read returns a new image, so a cached icon is told from a fresh one.
private final class PaneIconReads: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var keys: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    func load(_ key: String) -> NSImage {
        lock.lock(); paths.append(key); lock.unlock()
        return NSImage(size: NSSize(width: 24, height: 24))
    }
}

@MainActor private final class PaneFileStub: CommandFileSearching {
    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void) {}
    func stop() {}
}
