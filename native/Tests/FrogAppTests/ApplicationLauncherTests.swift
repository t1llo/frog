import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class ApplicationLauncherTests: XCTestCase {
    func testMovedApplicationUsesResolvedLocationAndOpenFailureIsReported() async throws {
        var rule = Rule(name: "Open fixture")
        rule.action = RuleAction(category: .application)
        rule.action?.applicationBundleID = "test.fixture"
        rule.action?.applicationPath = "/Old/Fixture.app"
        let error = FrogError.message("Fixture open failed")
        let launcher = ApplicationLauncher(resolve: { _ in URL(fileURLWithPath: "/New/Fixture.app") }, bundleIdentifier: { _ in "test.fixture" }, open: { url in
            XCTAssertEqual(url.path, "/New/Fixture.app")
            throw error
        })
        do { try await launcher.launch(rule); XCTFail("An open failure cannot be treated as success") }
        catch let actual as FrogError { XCTAssertEqual(actual, error) }
    }
    func testRunningApplicationStillReceivesOpenToRecreateClosedWindows() async throws {
        var rule = Rule(name: "Open fixture")
        rule.action = RuleAction(category: .application)
        rule.action?.applicationBundleID = "test.fixture"
        rule.action?.applicationPath = "/Applications/Fixture.app"
        var opened: URL?
        let launcher = ApplicationLauncher(resolve: { _ in nil }, bundleIdentifier: { _ in "test.fixture" }, open: { opened = $0 })
        try await launcher.launch(rule)
        XCTAssertEqual(opened?.path, "/Applications/Fixture.app", "Activating a running process alone does not reopen its closed windows")
    }
    func testChosenCopyOpensWhenAnotherCopySharesItsBundleIdentifier() async throws {
        var rule = Rule(name: "Open fixture")
        rule.action = RuleAction(category: .application)
        rule.action?.applicationBundleID = "test.fixture"
        rule.action?.applicationPath = "/Applications/Fixture Beta.app"
        var opened: URL?
        let launcher = ApplicationLauncher(resolve: { _ in URL(fileURLWithPath: "/Applications/Fixture.app") }, bundleIdentifier: { _ in "test.fixture" },
                                           exists: { $0.path == "/Applications/Fixture Beta.app" }, open: { opened = $0 })
        try await launcher.launch(rule)
        XCTAssertEqual(opened?.path, "/Applications/Fixture Beta.app", "Launch Services prefers one copy; the person chose this one")
    }
    func testReplacedApplicationFallsBackToItsBundleIdentifierOrAsksToChooseAgain() async throws {
        var rule = Rule(name: "Open fixture")
        rule.action = RuleAction(category: .application)
        rule.action?.applicationBundleID = "test.fixture"
        rule.action?.applicationPath = "/Applications/Fixture.app"
        var opened: URL?
        // Another application now lives at the stored path.
        let identifier: (URL) -> String? = { $0.path == "/Applications/Fixture.app" ? "test.other" : "test.fixture" }
        let moved = ApplicationLauncher(resolve: { _ in URL(fileURLWithPath: "/Applications/Moved/Fixture.app") }, bundleIdentifier: identifier,
                                        exists: { _ in true }, open: { opened = $0 })
        try await moved.launch(rule)
        XCTAssertEqual(opened?.path, "/Applications/Moved/Fixture.app")
        opened = nil
        let gone = ApplicationLauncher(resolve: { _ in nil }, bundleIdentifier: identifier, exists: { _ in true }, open: { opened = $0 })
        do { try await gone.launch(rule); XCTFail("A different application at the stored path must not open") }
        catch let actual as FrogError { XCTAssertEqual(actual, .message("Choose the application again; it has moved or been replaced.")) }
        XCTAssertNil(opened)
    }
}
