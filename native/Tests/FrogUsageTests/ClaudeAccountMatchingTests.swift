import XCTest
@testable import FrogUsage

/// Fake organization ids only; matching never touches a file.
final class ClaudeAccountMatchingTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/fixture/home")

    private func app(_ name: String, _ organization: String?) -> ClaudeAccountMatching.App {
        .init(folder: home.appendingPathComponent("Library/Application Support/\(name)"), organization: organization)
    }

    private func profile(_ name: String, _ organization: String?) -> ClaudeAccountMatching.Profile {
        let folder = home.appendingPathComponent(name)
        let file = name == ".claude" ? home.appendingPathComponent(".claude.json") : folder.appendingPathComponent(".claude.json")
        return .init(folder: folder, file: file, organization: organization)
    }

    func testProfileJoinsTheOneAppFolderOfItsOrganization() {
        let accounts = ClaudeAccountMatching.accounts(apps: [app("Claude", "org-test-1"), app("Claude-Account-B", "org-test-2")],
                                                      profiles: [profile(".claude", "org-test-1"), profile(".claude-work", "org-test-3")], home: home)
        XCTAssertEqual(accounts.map(\.defaultLabel), ["A", "B", "Work"])
        XCTAssertEqual(accounts[0].codeFolder?.lastPathComponent, ".claude")
        XCTAssertEqual(accounts[0].profileFile, home.appendingPathComponent(".claude.json"))
        XCTAssertNil(accounts[1].codeFolder, "An account known only from the Claude app has no login to read with")
        XCTAssertNil(accounts[2].appFolder)
        XCTAssertEqual(accounts[2].slotPath, "/fixture/home/.claude-work")
    }

    func testProfileStaysSeparateWhenTwoAppFoldersShareItsOrganization() {
        let accounts = ClaudeAccountMatching.accounts(apps: [app("Claude", "org-test-1"), app("Claude-2", "org-test-1")],
                                                      profiles: [profile(".claude", "org-test-1")], home: home)
        XCTAssertEqual(accounts.count, 2)
        XCTAssertNil(accounts[0].codeFolder)
        XCTAssertEqual(accounts[1].codeFolder?.lastPathComponent, ".claude")
    }

    func testAppFoldersOfOneOrganizationAreOneAccount() {
        let accounts = ClaudeAccountMatching.accounts(apps: [app("Claude", "org-test-1"), app("Claude-2", "org-test-1"),
                                                             app("Claude-3", nil), app("Claude-4", nil)], profiles: [], home: home)
        XCTAssertEqual(accounts.map { $0.appFolder?.lastPathComponent }, ["Claude", "Claude-3", "Claude-4"],
                       "Folders without an organization are never merged")
        XCTAssertEqual(accounts[0].mergedFolders.map(\.lastPathComponent), ["Claude-2"])
        XCTAssertEqual(accounts[0].mergedDescription, "Claude and Claude-2 are signed in to the same account")
        XCTAssertNil(accounts[1].mergedDescription)
    }

    func testFolderWhoseAccountChangedKeepsItsSlot() {
        let before = ClaudeAccountMatching.accounts(apps: [app("Claude-Account-B", "org-test-1")], profiles: [profile(".claude-b", "org-test-1")], home: home)
        let after = ClaudeAccountMatching.accounts(apps: [app("Claude-Account-B", "org-test-9")], profiles: [profile(".claude-b", "org-test-1")], home: home)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(after.first?.slotPath, before.first?.slotPath)
        XCTAssertEqual(after.first?.defaultLabel, "B")
        XCTAssertEqual(after.first?.pollingKey, before.first?.pollingKey)
        XCTAssertEqual(after.first?.organization, "org-test-9", "Only the newest sample's organization counts")
        XCTAssertNil(after.first?.codeFolder, "The profile no longer belongs to the folder")
        XCTAssertEqual(after.last?.codeFolder?.lastPathComponent, ".claude-b")
    }

    /// Every Claude app's Claude Code sessions write `~/.claude.json`, so while B's app ran one
    /// last, the default profile names B. A still reads `~/.claude`, and B its own folder.
    func testSharedDefaultProfileNamingBStillReadsForA() {
        let accounts = ClaudeAccountMatching.accounts(
            apps: [app("Claude", "org-test-1"), app("Claude-Account-B", "org-test-2")],
            profiles: [profile(".claude", "org-test-2"), profile(".claude-account-b", "org-test-2")], home: home)
        XCTAssertEqual(accounts.map(\.defaultLabel), ["A", "B"])
        XCTAssertEqual(accounts[0].codeFolder?.lastPathComponent, ".claude")
        XCTAssertEqual(accounts[0].profileFile, home.appendingPathComponent(".claude.json"))
        XCTAssertEqual(accounts[0].organization, "org-test-1", "The app folder's account names the slot")
        XCTAssertEqual(accounts[0].profileOrganization, "org-test-2")
        XCTAssertEqual(accounts[1].codeFolder?.lastPathComponent, ".claude-account-b")
        XCTAssertEqual(accounts[1].mergedFolders, [])
        XCTAssertNil(accounts[1].mergedDescription)

        let named = ClaudeAccountMatching.accounts(
            apps: [app("Claude", "org-test-1"), app("Claude-Account-B", "org-test-2")],
            profiles: [profile(".claude", "org-test-1"), profile(".claude-account-b", "org-test-2")], home: home)
        XCTAssertEqual(named.map { $0.codeFolder?.lastPathComponent }, accounts.map { $0.codeFolder?.lastPathComponent },
                       "Whichever account the default profile names, the folders stay paired the same way")
    }

    func testOwnFolderWinsOverTheDefaultProfileOfTheSameOrganization() {
        let accounts = ClaudeAccountMatching.accounts(
            apps: [app("Claude-Account-B", "org-test-2")],
            profiles: [profile(".claude", "org-test-2"), profile(".claude-account-b", "org-test-2")], home: home)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].codeFolder?.lastPathComponent, ".claude-account-b")
        XCTAssertEqual(accounts[0].mergedFolders.map(\.lastPathComponent), [".claude"], "No app folder of its own is left: folded in as before")
        XCTAssertEqual(accounts[0].codeFolders.map(\.lastPathComponent), [".claude-account-b", ".claude"])

        let otherName = ClaudeAccountMatching.accounts(
            apps: [app("Claude-Account-B", "org-test-2")],
            profiles: [profile(".claude", "org-test-2"), profile(".claude-work", "org-test-2")], home: home)
        XCTAssertEqual(otherName[0].codeFolder?.lastPathComponent, ".claude", "Without its own folder, the first profile of the account joins it")
        XCTAssertEqual(otherName[0].mergedFolders.map(\.lastPathComponent), [".claude-work"])
    }
}
