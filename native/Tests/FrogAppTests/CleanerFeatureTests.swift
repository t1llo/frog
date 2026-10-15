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
        XCTAssertEqual(one.title, "Moved 1 item to the Trash · 0 B")
        XCTAssertEqual(one.failureTitle, "Could not move 1 item")

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
