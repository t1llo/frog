import XCTest
import FrogCore
@testable import FrogApp

/// Windowless: a temporary data directory, and the cleaner always runs inside a fixture with fakes.
@MainActor final class CleanerFeatureTests: XCTestCase {
    private func makeModel(_ configuration: Configuration = Configuration(), fixture: CleanerFixture) throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ConfigurationStore(directory: directory).save(configuration)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil })
        model.cleanerDependencies = { .fake(root: fixture.root) }
        return (model, directory)
    }

    private func enableCleaner(_ model: AppModel) async throws -> AppCleanerPlugin {
        try await model.setFeature(.cleaner, enabled: true)
        await model.pluginHost.syncAndWait()
        return try XCTUnwrap(model.cleanerPlugin)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testTheRouteExistsOnlyWhileTheFeatureIsOn() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let (model, directory) = try makeModel(fixture: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(ToolkitRoute.feature(.cleaner).available(in: model.configuration.preferences))
        XCTAssertFalse(model.configuration.preferences.sidebarFeatures.contains(.cleaner))
        try await model.setFeature(.cleaner, enabled: true)
        XCTAssertTrue(ToolkitRoute.feature(.cleaner).available(in: model.configuration.preferences))
        XCTAssertTrue(model.configuration.preferences.sidebarFeatures.contains(.cleaner))
        model.toolkit.select(.feature(.cleaner))
        XCTAssertEqual(model.toolkit.route, .feature(.cleaner))
        try await model.setFeature(.cleaner, enabled: false)
        XCTAssertFalse(model.configuration.preferences.sidebarFeatures.contains(.cleaner))
        XCTAssertNotEqual(model.toolkit.route, .feature(.cleaner))
    }

    func testTurningThePluginOffStopsAndDropsTheCleaner() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Chatter", bundleID: "com.example.chatter")
        let cache = try fixture.item(.caches, "com.example.chatter", bytes: 64)
        let (model, directory) = try makeModel(fixture: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let cleaner = try await enableCleaner(model).cleaner

        await cleaner.open(app)
        await cleaner.prepareRemoval()
        XCTAssertNotNil(cleaner.pending, "The confirmation is open")
        cleaner.issue = "Something to say."

        try await model.setFeature(.cleaner, enabled: false)
        await model.pluginHost.syncAndWait()

        XCTAssertNil(model.cleanerPlugin)
        XCTAssertNil(cleaner.issue)
        XCTAssertNil(cleaner.pending)
        XCTAssertNil(cleaner.review)
        XCTAssertTrue(cleaner.apps.isEmpty)
        XCTAssertEqual(cleaner.phase, .idle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path), "Nothing moved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path), "Nothing moved")
    }

    func testRemovalSummaryTexts() {
        let format: (Int64) -> String = { "\($0) B" }
        func entry(_ path: String, _ bytes: Int64?) -> RemovalRecord.Entry {
            RemovalRecord.Entry(original: path, trashed: nil, bytes: bytes, route: .fileManager, owner: .user)
        }
        let many = RemovalSummary(RemovalOutcome(moved: (1...12).map { entry("/a/\($0)", 100) }, notes: ["A note."]),
                                  formatBytes: format)
        XCTAssertEqual(many.title, "Moved 12 items to the Trash · 1200 B")
        XCTAssertNil(many.failureTitle)
        XCTAssertEqual(many.notes, ["A note.", "Empty the Trash to free the space."])

        let one = RemovalSummary(RemovalOutcome(moved: [entry("/a", nil)],
                                                failures: [RemovalFailure(path: "/b", message: "No.")]), formatBytes: format)
        XCTAssertEqual(one.title, "Moved 1 item to the Trash", "No size is known, so none is shown")
        XCTAssertEqual(one.failureTitle, "Could not move 1 item")
        let partly = RemovalSummary(RemovalOutcome(moved: [entry("/a", 100), entry("/b", nil)]), formatBytes: format)
        XCTAssertEqual(partly.title, "Moved 2 items to the Trash · at least 100 B")

        let none = RemovalSummary(RemovalOutcome(failures: [RemovalFailure(path: "/a", message: "No."),
                                                            RemovalFailure(path: "/b", message: "No.")]), formatBytes: format)
        XCTAssertEqual(none.title, "Nothing was moved.")
        XCTAssertEqual(none.failureTitle, "Could not move 2 items")
        XCTAssertEqual(none.notes, [], "Nothing moved, so there is no space to free")
        XCTAssertEqual(RemovalSummary(RemovalOutcome(cancelled: true)).title, "Nothing was moved.")

        XCTAssertEqual(RemovalSummary.settingsLink(for: CleanerRemover.automationDenied), .automation)
        XCTAssertEqual(RemovalSummary.settingsLink(for: CleanerRemover.needsFullDiskAccess), .fullDiskAccess)
        XCTAssertNil(RemovalSummary.settingsLink(for: "No."))
        XCTAssertTrue(RemovalSummary.SettingsLink.automation.url.absoluteString.hasSuffix("?Privacy_Automation"))
        XCTAssertTrue(RemovalSummary.SettingsLink.fullDiskAccess.url.absoluteString.hasSuffix("?Privacy_AllFiles"))
    }

    func testTheReviewCountsAnItemInsideATickedFolderOnce() {
        let format: (Int64) -> String = { "\($0) B" }
        func item(_ path: String, size: Int64? = nil) -> CleanerItem {
            CleanerItem(url: URL(fileURLWithPath: path), kind: .folder, confidence: .certain, reason: "Named after the bundle ID.",
                        size: size)
        }
        let vendor = item("/fixture/Library/Application Support/Vendor")
        let inside = item("/fixture/Library/Application Support/Vendor/Example")
        let cache = item("/fixture/Library/Caches/com.example.app")
        let lookalike = item("/fixture/Library/Application Support/Vendor Tools")
        let app = AppIdentity(path: "/fixture/Applications/Example.app", name: "Example", bundleID: "com.example.app")
        var review = CleanerReview(app: app, items: [vendor, inside, cache, lookalike], selected: [], sizes: [:],
                                   fullDiskAccess: true)
        XCTAssertEqual(review.selectionSummary(formatBytes: format), "Nothing ticked")

        review.selected = Set([vendor, inside, cache, lookalike].map(\.id))
        XCTAssertEqual(review.tickedItems.map(\.id), [vendor, cache, lookalike].map(\.id),
                       "The folder inside Vendor moves with it; Vendor Tools is a folder of its own")
        XCTAssertEqual(review.selectionSummary(formatBytes: format), "3 items", "No size is known yet")

        review.sizes = [vendor.id: CleanerSize(bytes: 300, complete: true), inside.id: CleanerSize(bytes: 200, complete: true),
                        cache.id: CleanerSize(bytes: 50, complete: true)]
        XCTAssertEqual(review.selectedBytes, 350)
        XCTAssertEqual(review.selectionSummary(formatBytes: format), "3 items · at least 350 B")
        review.sizes[lookalike.id] = CleanerSize(bytes: 1, complete: true)
        XCTAssertEqual(review.selectionSummary(formatBytes: format), "3 items · 351 B")
        review.sizes[cache.id] = CleanerSize(bytes: 50, complete: false)
        XCTAssertEqual(review.selectionSummary(formatBytes: format), "3 items · at least 351 B")
        XCTAssertEqual(CleanerFormat.bytes(0), "0 bytes")
    }

    func testTheReviewSaysWhatFullDiskAccessIsNeededFor() {
        func item(_ path: String, _ kind: CleanerItemKind, confidence: MatchConfidence = .certain) -> CleanerItem {
            CleanerItem(url: URL(fileURLWithPath: path), kind: kind, confidence: confidence, reason: "Named after the bundle ID.")
        }
        let app = AppIdentity(path: "/fixture/Applications/Example.app", name: "Example", bundleID: "com.example.app")
        let bundle = item(app.path, .application)
        let container = item("/fixture/Library/Containers/com.example.app", .container)
        var cookies = item("/fixture/Library/Cookies/com.example.app.binarycookies", .file)
        cookies.needsFullDiskAccess = true
        var review = CleanerReview(app: app, items: [bundle, container], selected: [], sizes: [:], fullDiskAccess: false)
        XCTAssertFalse(review.needsFullDiskAccessToMove(container), "Finder moves containers")
        XCTAssertEqual(review.fullDiskAccessNotice,
                       "Without Full Disk Access, Frog cannot measure some items. Finder can still move them.")
        review.items.append(cookies)
        XCTAssertTrue(review.needsFullDiskAccessToMove(cookies))
        XCTAssertEqual(review.fullDiskAccessNotice, "Some items need Full Disk Access to be measured or moved.")
        review.fullDiskAccess = true
        XCTAssertNil(review.fullDiskAccessNotice)
        XCTAssertFalse(review.needsFullDiskAccessToMove(cookies))
    }

    func testTheReviewSaysWhenOnlyTheAppWasFound() {
        let app = AppIdentity(path: "/fixture/Applications/Example.app", name: "Example", bundleID: "com.example.app")
        let bundle = CleanerItem(url: app.url, kind: .application, confidence: .certain, reason: "The app itself.")
        let possible = CleanerItem(url: URL(fileURLWithPath: "/fixture/Library/Logs/ExampleSync"), kind: .folder,
                                   confidence: .possible, reason: "Name contains example.")
        var review = CleanerReview(app: app, items: [bundle], selected: [], sizes: [:], fullDiskAccess: true)
        XCTAssertEqual(review.nothingElseFound(showPossible: false), "Frog found no other files of Example.")
        review.items.append(possible)
        XCTAssertEqual(review.nothingElseFound(showPossible: false),
                       "Frog found no other files of Example it is sure about. 1 possible match is hidden.")
        XCTAssertNil(review.nothingElseFound(showPossible: true))
    }

    func testSettingsAreSeededOnceFromTheOldPreferences() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        var configuration = Configuration()
        configuration.preferences.ensureToolkit()
        configuration.preferences.toolkit?.cleaner = { var value = CleanerPreferences(); value.possibleMatches = true; return value }()
        let (model, directory) = try makeModel(configuration, fixture: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }

        let plugin = try await enableCleaner(model)
        XCTAssertTrue(plugin.settings.possibleMatches)
        XCTAssertTrue(plugin.cleaner.showPossibleMatches)
        let text = try String(contentsOf: model.settingsFile.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[app-cleaner]") && text.contains("possible-matches = true"), text)

        // From now on config.toml alone decides.
        plugin.update { $0.possibleMatches = false }
        XCTAssertFalse(plugin.cleaner.showPossibleMatches)
        try await model.setFeature(.cleaner, enabled: false)
        await model.pluginHost.syncAndWait()
        let again = try await enableCleaner(model)
        XCTAssertFalse(again.settings.possibleMatches, "The old preference is not read a second time")
        XCTAssertEqual(try model.settingsFile.section("app-cleaner", as: AppCleanerSettings.self).value, AppCleanerSettings())
    }

    func testTheCleanerUsesTheInjectedDependenciesAndWaitsForFirstUse() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let (model, directory) = try makeModel(fixture: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        var made = 0
        model.cleanerDependencies = { made += 1; return .fake(root: fixture.root) }
        let plugin = try await enableCleaner(model)
        XCTAssertEqual(made, 0, "Starting the plugin reads nothing")

        XCTAssertEqual(plugin.cleaner.dependencies.store.directory.standardizedFileURL,
                       fixture.root.appendingPathComponent("data/Cleaner", isDirectory: true).standardizedFileURL)
        XCTAssertEqual(plugin.cleaner.dependencies.roots.home.path,
                       CleanerRoots(home: fixture.home, system: fixture.system).home.path)
        XCTAssertTrue(plugin.cleaner === plugin.cleaner, "The model is made once")
        XCTAssertEqual(made, 1)
    }

    func testScanListsLeftoversAndMovesNothing() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Chatter", bundleID: "com.example.chatter")
        let cache = try fixture.item(.caches, "com.example.chatter", bytes: 64)
        let (model, directory) = try makeModel(fixture: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        _ = try await enableCleaner(model)

        let result = try await model.pluginHost.run("app-cleaner.scan", ActionInput(values: ["app": "Chatter"], source: .agent))
        let json = try object(result.json)
        XCTAssertEqual(json["bundleID"] as? String, "com.example.chatter")
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        let paths = items.compactMap { $0["path"] as? String }.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        XCTAssertTrue(paths.contains(cache.standardizedFileURL.path), "\(paths)")
        XCTAssertTrue(paths.contains(app.standardizedFileURL.path), "\(paths)")
        XCTAssertTrue(result.text.contains("com.example.chatter"), result.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))

        // By bundle ID too; an unknown app says so.
        let byID = try await model.pluginHost.run("app-cleaner.scan", ActionInput(values: ["app": "com.example.chatter"], source: .agent))
        XCTAssertEqual(try object(byID.json)["app"] as? String, "Chatter")
        do {
            _ = try await model.pluginHost.run("app-cleaner.scan", ActionInput(values: ["app": "Nothing Here"], source: .agent))
            XCTFail("No such app")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Nothing Here"), error.localizedDescription) }
        do {
            _ = try await model.pluginHost.run("app-cleaner.scan", ActionInput(source: .agent))
            XCTFail("--app is required")
        } catch ActionError.missing(let name) { XCTAssertEqual(name, "app") }
    }

    func testUninstallNeedsConfirmAndOnlyEverMovesToTheTrash() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Chatter", bundleID: "com.example.chatter")
        let cache = try fixture.item(.caches, "com.example.chatter", bytes: 64)
        let (model, directory) = try makeModel(fixture: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let trash = fixture.root.appendingPathComponent("Trash", isDirectory: true)
        let log = CleanerCallLog()
        model.cleanerDependencies = { .fake(root: fixture.root, trash: FakeCleanerTrash(folder: trash, log: log)) }
        _ = try await enableCleaner(model)

        do {
            _ = try await model.pluginHost.run("app-cleaner.uninstall", ActionInput(values: ["app": "Chatter"], source: .agent))
            XCTFail("Uninstalling needs --confirm")
        } catch { XCTAssertTrue(error.localizedDescription.contains("--confirm"), error.localizedDescription) }
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))

        let result = try await model.pluginHost.run("app-cleaner.uninstall",
                                                    ActionInput(values: ["app": "Chatter", "confirm": "true"], source: .agent))
        let json = try object(result.json)
        XCTAssertEqual((json["moved"] as? [String])?.count, 2, result.json)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Chatter.app").path), "In the fake Trash")
        XCTAssertTrue(log.entries.allSatisfy { $0.hasPrefix("trash") || $0.hasPrefix("finder") }, "\(log.entries)")
    }

    func testAnUninstallUnderWayRefusesAnotherAndShowsOnThePage() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Chatter", bundleID: "com.example.chatter")
        _ = try fixture.item(.caches, "com.example.chatter", bytes: 64)
        let (model, directory) = try makeModel(fixture: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let trash = FakeCleanerTrash(folder: fixture.root.appendingPathComponent("Trash", isDirectory: true))
        model.cleanerDependencies = { .fake(root: fixture.root, trash: trash) }
        _ = try await enableCleaner(model)
        let cleaner = try XCTUnwrap(model.cleanerPlugin?.cleaner)
        func removing() -> Bool { if case .removing = cleaner.phase { return true }; return false }

        await trash.hold()
        let input = ActionInput(values: ["app": "Chatter", "confirm": "true"], source: .agent)
        let first = Task { try await model.pluginHost.run("app-cleaner.uninstall", input) }
        for _ in 0..<500 where !removing() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(removing(), "The page shows the agent's removal and starts none of its own")
        do {
            _ = try await model.pluginHost.run("app-cleaner.uninstall", input)
            XCTFail("A second removal waits for the first")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Finish the removal"), error.localizedDescription) }

        await trash.release()
        let result = try await first.value
        XCTAssertEqual((try object(result.json)["moved"] as? [String])?.count, 2, result.json)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        XCTAssertFalse(removing(), "The page is free again")
    }

    func testUninstallRefusesARunningApp() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Chatter", bundleID: "com.example.chatter")
        let (model, directory) = try makeModel(fixture: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let system = FakeCleanerSystem()
        await system.setRunning([RunningAppInfo(pid: 42, bundleID: "com.example.chatter", name: "Chatter", bundlePath: app.path)])
        model.cleanerDependencies = { .fake(root: fixture.root, system: system) }
        _ = try await enableCleaner(model)

        do {
            _ = try await model.pluginHost.run("app-cleaner.uninstall",
                                               ActionInput(values: ["app": "Chatter", "confirm": "true"], source: .agent))
            XCTFail("A running app stays")
        } catch { XCTAssertTrue(error.localizedDescription.contains("running"), error.localizedDescription) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }

    /// `cleaner-list-*.png` and `cleaner-review-*.png`: the fixture's apps, and the review of one of them.
    func testPageShotsOfTheListAndAReview() async throws {
        guard ProcessInfo.processInfo.environment["FROG_PAGE_SHOTS"] != nil else { throw XCTSkip("Set FROG_PAGE_SHOTS") }
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Chatter", bundleID: "com.example.chatter", payload: 4_000_000)
        _ = try fixture.app("Sketchbook", bundleID: "com.example.sketchbook", payload: 9_000_000)
        _ = try fixture.app("Notebook", bundleID: "com.example.notebook", payload: 600_000)
        _ = try fixture.item(.caches, "com.example.chatter", bytes: 2_000_000)
        _ = try fixture.item(.applicationSupport, "Chatter", bytes: 800_000)
        _ = try fixture.item(.preferences, "com.example.chatter.plist", bytes: 4_000)
        let (model, directory) = try makeModel(fixture: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let plugin = try await enableCleaner(model)
        await plugin.cleaner.loadApps()
        await plugin.cleaner.measureAppSizes()
        try await savePluginPageShot("cleaner-list", model: model) { plugin.page()! }
        await plugin.cleaner.open(app)
        await plugin.cleaner.waitForSizes()
        try await savePluginPageShot("cleaner-review", model: model) { plugin.page()! }
    }
}
