import XCTest
@testable import FrogUsage

/// Labels live in an isolated defaults suite, never in Frog's own.
final class ClaudeAccountLabelsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/fixture/home")
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "frog-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func app(_ name: String) -> ClaudeAccountSource { .app(home.appendingPathComponent("Library/Application Support/\(name)")) }
    private func code(_ name: String) -> ClaudeAccountSource {
        .code(home.appendingPathComponent(name), profile: home.appendingPathComponent("\(name)/.claude.json"))
    }

    private func accounts() -> [ClaudeAccount] {
        ClaudeAccountMatching.accounts(
            apps: ["Claude", "Claude-Account-B", "Claude C"].map { .init(folder: home.appendingPathComponent("Library/Application Support/\($0)"), organization: nil) },
            profiles: [".claude-work", ".claude-team-x"].map { .init(folder: home.appendingPathComponent($0), file: home.appendingPathComponent("\($0)/.claude.json"), organization: nil) }, home: home)
    }

    func testDefaultLabels() {
        XCTAssertEqual(ClaudeAccountLabels.defaultLabels(for: [app("Claude"), app("Claude-Account-B"), app("Claude C"), app("claude-d"),
                                                                code(".claude-work"), code(".claude-account-e")]),
                       ["A", "B", "C", "D", "Work", "E"])
        // Folders that name no letter take the next one nobody has, app folders first.
        XCTAssertEqual(ClaudeAccountLabels.defaultLabels(for: [app("Claude-2"), app("Claude-Account-B"), app("Claude-Work"), code(".claude")]),
                       ["A", "B", "C", "D"])
        XCTAssertEqual(ClaudeAccountLabels.defaultLabels(for: [app("Claude"), app("Claude-A"), code(".claude-b")]), ["A", "C", "B"],
                       "A letter already taken is not given twice")
    }

    func testRenameTrimsLimitsAndKeepsLabelsUnique() {
        let labels = ClaudeAccountLabels(defaults: defaults), accounts = accounts()
        XCTAssertEqual(accounts.map { labels.label(for: $0) }, ["A", "B", "C", "Work", "Team-x"])
        XCTAssertEqual(labels.rename(accounts[0], to: "  Personal  ", among: accounts), "Personal")
        XCTAssertEqual(labels.rename(accounts[1], to: "A much longer name than allowed", among: accounts), "A much longer na")
        XCTAssertEqual(labels.rename(accounts[2], to: "personal", among: accounts), "personal 2")
        XCTAssertEqual(labels.rename(accounts[3], to: "Personal", among: accounts), "Personal 3")
        XCTAssertEqual(labels.rename(accounts[4], to: "A much longer name than allowed", among: accounts), "A much longer 2")
        XCTAssertEqual(labels.rename(accounts[0], to: "   ", among: accounts), "A", "Empty returns to the default")
        XCTAssertEqual(ClaudeAccountLabels.shortLabel("Personal"), "Person")

        // Saved by slot, so a new instance and a new discovery find them again.
        let again = ClaudeAccountLabels(defaults: defaults)
        XCTAssertEqual(self.accounts().map { again.label(for: $0) }, ["A", "A much longer na", "personal 2", "Personal 3", "A much longer 2"])
        XCTAssertTrue(again.isIncluded(accounts[1]))
        again.setIncluded(false, for: accounts[1])
        XCTAssertFalse(ClaudeAccountLabels(defaults: defaults).isIncluded(accounts[1]))
        XCTAssertEqual(ClaudeAccountLabels(defaults: defaults).label(for: accounts[1]), "A much longer na")
    }

    func testLabelsAreNeverPartOfTheDisplayPreferences() throws {
        let labels = ClaudeAccountLabels(defaults: defaults), accounts = accounts()
        labels.rename(accounts[0], to: "Secret label", among: accounts)
        let preferences = UsageDashboardPreferences(claudeAccounts: true, claudeAccountsView: "combined")
        let text = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
        XCTAssertFalse(text.contains("Secret label"))
        XCTAssertFalse(text.contains("fixture"))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["provider", "range", "metric", "allDevices", "loginSource",
                                   "claudeAccounts", "claudeAccountsView", "claudeAccountsMenuBar"])
    }

    func testPollingKeys() {
        let accounts = accounts()
        XCTAssertEqual(accounts[0].pollingKey, ClaudePollingState.defaultsKey, "The default Claude folder keeps the key from before")
        XCTAssertTrue(accounts[1].pollingKey.hasPrefix(ClaudePollingState.defaultsKey + "."))
        XCTAssertEqual(accounts[1].pollingKey.count, ClaudePollingState.defaultsKey.count + 17)
        XCTAssertEqual(self.accounts()[1].pollingKey, accounts[1].pollingKey, "Stable from one run to the next")
        XCTAssertEqual(Set(accounts.map(\.pollingKey)).count, accounts.count)

        // Without the default Claude folder, the default profile keeps it.
        let profileOnly = ClaudeAccountMatching.accounts(
            apps: [.init(folder: home.appendingPathComponent("Library/Application Support/Claude-B"), organization: "org-test-2")],
            profiles: [.init(folder: home.appendingPathComponent(".claude"), file: home.appendingPathComponent(".claude.json"), organization: "org-test-1")], home: home)
        XCTAssertEqual(profileOnly.map(\.pollingKey).last, ClaudePollingState.defaultsKey)
        XCTAssertNotEqual(profileOnly.first?.pollingKey, ClaudePollingState.defaultsKey)
    }
}
