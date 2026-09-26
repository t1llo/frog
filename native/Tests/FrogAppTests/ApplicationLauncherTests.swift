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
}
