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

    func testTurningTheFeatureOffStopsTheCleaner() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Chatter", bundleID: "com.example.chatter")
        let cache = try fixture.item(.caches, "com.example.chatter", bytes: 64)
        let (model, directory) = try makeModel(fixture: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        try await model.setFeature(.cleaner, enabled: true)

        await model.cleaner.open(app)
        await model.cleaner.prepareRemoval()
        XCTAssertNotNil(model.cleaner.pending, "The confirmation is open")
        model.cleaner.issue = "Something to say."

        try await model.setFeature(.cleaner, enabled: false)

        XCTAssertNil(model.cleaner.issue)
        XCTAssertNil(model.cleaner.pending)
        XCTAssertNil(model.cleaner.review)
        XCTAssertTrue(model.cleaner.apps.isEmpty)
        XCTAssertEqual(model.cleaner.phase, .idle)
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

    func testUpdatingCleanerSettingsKeepsTheRestOfTheToolkit() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        var configuration = Configuration()
        configuration.preferences.setFeature(.scripts, enabled: true)
        let (model, directory) = try makeModel(configuration, fixture: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }

        try model.updateCleanerSettings { $0.possibleMatches = true }

        XCTAssertTrue(model.configuration.preferences.featureEnabled(.scripts))
        XCTAssertTrue(model.configuration.preferences.cleanerSettings.possibleMatches)
        let saved = try ConfigurationStore(directory: directory).load()
        XCTAssertTrue(saved.preferences.featureEnabled(.scripts))
        XCTAssertTrue(saved.preferences.cleanerSettings.possibleMatches)
        XCTAssertTrue(try String(contentsOf: ConfigurationStore(directory: directory).textFile, encoding: .utf8)
            .contains("cleaner.possible-matches = true"))

        // Without a toolkit, the change creates one the way Features does.
        var bare = Configuration()
        bare.preferences.toolkit = nil
        let (other, otherDirectory) = try makeModel(bare, fixture: fixture)
        defer { other.shutdown(); try? FileManager.default.removeItem(at: otherDirectory) }
        var expected = other.configuration.preferences
        expected.ensureToolkit()
        expected.toolkit?.cleaner = { var value = CleanerPreferences(); value.possibleMatches = true; return value }()
        try other.updateCleanerSettings { $0.possibleMatches = true }
        XCTAssertEqual(other.configuration.preferences, expected)
    }

    func testTheCleanerUsesTheInjectedDependencies() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let (model, directory) = try makeModel(fixture: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(model.cleaner.dependencies.store.directory.standardizedFileURL,
                       fixture.root.appendingPathComponent("data/Cleaner", isDirectory: true).standardizedFileURL)
        XCTAssertEqual(model.cleaner.dependencies.roots.home.path,
                       CleanerRoots(home: fixture.home, system: fixture.system).home.path)
        XCTAssertTrue(model.cleaner === model.cleaner, "The model is made once")
    }

    func testSavingPreferencesUpdatesTheCleaner() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        var configuration = Configuration()
        configuration.preferences.setFeature(.cleaner, enabled: true)
        let (model, directory) = try makeModel(configuration, fixture: fixture)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(model.cleaner.showPossibleMatches)

        try model.updateCleanerSettings { $0.possibleMatches = true }
        XCTAssertTrue(model.cleaner.showPossibleMatches)

        try await model.setFeature(.cleaner, enabled: false)
        XCTAssertFalse(model.cleaner.showPossibleMatches, "Sub-switches count only while the cleaner is on")
        XCTAssertEqual(model.cleaner.tab, .apps)

        // A model made after the save starts from the saved switch.
        try await model.setFeature(.cleaner, enabled: true)
        let (other, otherDirectory) = try makeModel(model.configuration, fixture: fixture)
        defer { other.shutdown(); try? FileManager.default.removeItem(at: otherDirectory) }
        XCTAssertTrue(other.cleaner.showPossibleMatches)
    }
}
