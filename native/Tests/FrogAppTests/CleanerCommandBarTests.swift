import AppKit
import XCTest
import FrogCore
@testable import FrogApp

/// "Uninstall <App>" rows in the command bar, decided without presenting its panel. The apps are fixture bundles in
/// a temporary folder and the cleaner runs with a fake Trash.
@MainActor final class CleanerCommandBarTests: XCTestCase {
    private var fixture: CleanerFixture!
    private var directory: URL!
    private var pasteboard: NSPasteboard!
    private var model: AppModel!
    private var log: CleanerCallLog!

    override func setUp() async throws {
        fixture = try CleanerFixture()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        log = CleanerCallLog()
    }

    override func tearDown() async throws {
        model?.shutdown(); model = nil
        pasteboard.releaseGlobally(); pasteboard = nil
        try? FileManager.default.removeItem(at: directory)
        fixture.remove()
    }

    /// The configuration is saved before the model starts, so no save warms the real command bar.
    private func makeModel(cleaner: Bool) throws -> AppModel {
        var config = Configuration(); config.preferences.windowSwitcherEnabled = false
        config.preferences.setFeature(.commandBar, enabled: true)
        config.preferences.setFeature(.cleaner, enabled: cleaner)
        try ConfigurationStore(directory: directory).save(config)
        let model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil },
                             clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard))
        let root = fixture.root, log = log!
        model.cleanerDependencies = {
            .fake(root: root, trash: FakeCleanerTrash(folder: root.appendingPathComponent("Trash", isDirectory: true), log: log))
        }
        self.model = model
        return model
    }

    private func rule(_ name: String, path: String, bundleID: String) -> Rule {
        var rule = Rule(name: name, instructions: "", enabled: false)
        rule.action = RuleAction(category: .application)
        rule.action?.applicationPath = path
        rule.action?.applicationBundleID = bundleID
        return rule
    }

    /// A bar with the cleaner's rows for the fixture's Applications folder, and the apps cached as the bar caches them.
    private func bar(_ rules: [Rule], own: String = "/fixture/Frog.app") -> CommandBar {
        let apps = rules.compactMap { rule -> CleanerCommandApp? in
            guard let path = rule.action?.applicationPath else { return nil }
            return CleanerCommandApp(record: SearchRecord(id: "app:\(path)", title: rule.name, subtitle: "App", symbol: "app", prominent: true),
                                     path: path, bundleID: rule.action?.applicationBundleID)
        }
        let rows = CleanerCommandRows(applications: { apps }, ownBundlePath: own,
                                      applicationFolders: [fixture.applications, fixture.homeApplications])
        let bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, waitForRelease: {},
                             fileSearch: CleanerFileStub(), loadSettings: { [] }, loadApplications: { rules },
                             extraProviders: [rows])
        bar.cacheApplications(rules)
        return bar
    }

    private func fixtureApp(_ name: String, bundleID: String) throws -> Rule {
        rule(name, path: try fixture.app(name, bundleID: bundleID).path, bundleID: bundleID)
    }

    func testUninstallRowsAppearOnlyWithTheCleanerOn() throws {
        let app = try fixtureApp("Fixture App", bundleID: "com.example.fixture")
        let path = try XCTUnwrap(app.action?.applicationPath)
        _ = try makeModel(cleaner: false)
        let off = bar([app])
        defer { off.stop() }
        off.prepareResults(model, frontPID: nil)
        off.query = "uninstall fixture"
        XCTAssertFalse(off.results.contains { $0.id.hasPrefix("uninstall:") })
        model.shutdown()

        _ = try makeModel(cleaner: true)
        let on = bar([app])
        defer { on.stop() }
        on.prepareResults(model, frontPID: nil)
        on.query = "fixture"
        XCTAssertEqual(on.results.first?.id, "app:\(path)", "The app itself is ranked as before")
        XCTAssertFalse(on.results.contains { $0.id.hasPrefix("uninstall:") }, "Only the typed verb offers a removal")
        on.query = "uninstall fixture"
        let first = try XCTUnwrap(on.results.first)
        XCTAssertEqual(first.id, CleanerCommand.rowID(path: path))
        XCTAssertEqual(first.title, "Uninstall Fixture App")
        XCTAssertEqual(first.subtitle, "App cleaner · Review before anything moves")
        if let ranked = on.results.firstIndex(where: { $0.id == "app:\(path)" }) { XCTAssertGreaterThan(ranked, 0) }
        on.query = "remove fix"
        XCTAssertEqual(on.results.first?.id, CleanerCommand.rowID(path: path))
    }

    func testAtMostThreeAppsAreOffered() throws {
        let rules = try ["Fixture One", "Fixture Two", "Fixture Three", "Fixture Four", "Fixture Five"].map {
            try fixtureApp($0, bundleID: "com.example.\($0.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }
        _ = try makeModel(cleaner: true)
        let bar = bar(rules)
        defer { bar.stop() }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "uninstall fixture"
        let offered = bar.results.filter { $0.id.hasPrefix("uninstall:") }
        XCTAssertEqual(offered.count, 3)
        XCTAssertEqual(Array(bar.results.prefix(3)), offered)
    }

    func testChoosingTheRowOpensTheReviewAndMovesNothing() async throws {
        let app = try fixtureApp("Fixture App", bundleID: "com.example.fixture")
        let path = try XCTUnwrap(app.action?.applicationPath)
        try fixture.item(.caches, "com.example.fixture", bytes: 64)
        _ = try makeModel(cleaner: true)
        let bar = bar([app])
        defer { bar.stop() }
        var chosen = 0
        bar.onToolUse = { if $0 == .commandSelection { chosen += 1 } }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "uninstall fixture app"
        XCTAssertEqual(bar.results.first?.id, CleanerCommand.rowID(path: path))

        bar.choose(0)
        for _ in 0..<400 where chosen == 0 { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertEqual(chosen, 1)
        XCTAssertEqual(model.toolkit.route, .feature(.cleaner))
        XCTAssertTrue([.scanning, .reviewing].contains(model.cleaner.phase))
        XCTAssertEqual(model.cleaner.review?.app.bundleID, "com.example.fixture")
        XCTAssertNil(model.cleaner.pending, "The confirmation is the page's step")
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("trash") || $0.hasPrefix("finder") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        // A removal answers only its own query and is never suggested again.
        bar.prepareResults(model, frontPID: nil)
        XCTAssertFalse(bar.results.contains { $0.id.hasPrefix("uninstall:") })
    }

    func testFrogItselfIsNeverOffered() throws {
        let frog = try fixtureApp("Frog Fixture", bundleID: "com.example.frog-fixture")
        let other = try fixtureApp("Frogger Fixture", bundleID: "com.example.frogger")
        let apple = rule("Fixture Notes", path: try fixture.app("Fixture Notes", bundleID: "com.apple.fixture-notes").path,
                         bundleID: "com.apple.fixture-notes")
        _ = try makeModel(cleaner: true)
        let bar = bar([frog, other, apple], own: try XCTUnwrap(frog.action?.applicationPath))
        defer { bar.stop() }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "uninstall fixture"
        XCTAssertEqual(bar.results.filter { $0.id.hasPrefix("uninstall:") }.map(\.title), ["Uninstall Frogger Fixture"])
    }

    func testHidingTheBarDropsTheRowActions() throws {
        let app = try fixtureApp("Fixture App", bundleID: "com.example.fixture")
        _ = try makeModel(cleaner: true)
        let bar = bar([app])
        defer { bar.stop() }
        bar.prepareResults(model, frontPID: nil)
        bar.query = "uninstall fixture"
        XCTAssertTrue(bar.results.first?.id.hasPrefix("uninstall:") == true)

        bar.hide()
        XCTAssertEqual(bar.results, [])
        bar.choose(0)
        XCTAssertNotEqual(model.toolkit.route, .feature(.cleaner))
        // Opening the bar again lists no removal until the verb is typed again.
        bar.prepareResults(model, frontPID: nil)
        XCTAssertFalse(bar.results.contains { $0.id.hasPrefix("uninstall:") })
    }
}

@MainActor private final class CleanerFileStub: CommandFileSearching {
    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void) {}
    func stop() {}
}
