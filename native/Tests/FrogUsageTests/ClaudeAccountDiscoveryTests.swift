import FrogTestSupport
import XCTest
@testable import FrogUsage

/// A fixture home only; no test looks at this Mac's real folders.
final class ClaudeAccountDiscoveryTests: XCTestCase {
    private var home: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("frog-accounts-\(UUID().uuidString)")
        defaults = temporaryDefaults()
        let support = home.appendingPathComponent("Library/Application Support")
        for (folder, file) in [("Claude", "plan-usage-history.json"), ("Claude-Account-B", "plan-usage-history.json"),
                               ("ClaudeUsageBar", "leaderboard.json"), ("Slack", "plan-usage-history.json"),
                               ("Claude-Empty", "config.json")] {
            try write("{}", to: support.appendingPathComponent("\(folder)/\(file)"))
        }
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Claude B/claude-code-sessions"),
                                                withIntermediateDirectories: true)
        try write(#"{"oauthAccount":{"organizationUuid":"org-test-1"}}"#, to: home.appendingPathComponent(".claude.json"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try write(#"{"oauthAccount":{"organizationUuid":"org-test-2"}}"#, to: home.appendingPathComponent(".claude-work/.claude.json"))
        try write(#"{"numStartups":3}"#, to: home.appendingPathComponent(".claude-signed-out/.claude.json"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude-worktrees"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("links"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("links/work"),
                                                   withDestinationURL: home.appendingPathComponent(".claude-work"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func sources(read: (URL) -> Data? = { try? Data(contentsOf: $0) }) -> [ClaudeAccountSource] {
        ClaudeAccountDiscovery.sources(home: home, extraFolders: [home.appendingPathComponent("links/work")],
                                       environment: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path],
                                       defaults: defaults, read: read)
    }

    func testKeepsClaudeAppFoldersAndSignedInProfilesOnce() {
        let support = home.appendingPathComponent("Library/Application Support")
        XCTAssertEqual(sources().map { $0.folder.lastPathComponent }, ["Claude", "Claude B", "Claude-Account-B", ".claude", ".claude-work"],
                       "Other apps, a folder without history, a signed-out profile and duplicates are left out")
        XCTAssertEqual(sources().first, .app(support.appendingPathComponent("Claude").standardizedFileURL))
        XCTAssertEqual(sources()[3], .code(home.appendingPathComponent(".claude").standardizedFileURL,
                                           profile: home.appendingPathComponent(".claude.json")),
                       "The default profile keeps its file in the home folder")
        XCTAssertEqual(sources()[4], .code(home.appendingPathComponent(".claude-work").standardizedFileURL,
                                           profile: home.appendingPathComponent(".claude-work/.claude.json").standardizedFileURL))
    }

    func testOpensNoFileButTheProfiles() {
        var opened: [String] = []
        _ = sources { url in opened.append(url.lastPathComponent + "@" + url.deletingLastPathComponent().lastPathComponent); return try? Data(contentsOf: url) }
        let homeName = home.lastPathComponent
        XCTAssertEqual(Set(opened), [".claude.json@\(homeName)", ".claude.json@.claude-work", ".claude.json@.claude-signed-out"],
                       "Only profile files are read; app folders are only checked for their files")
    }

    func testChosenFolderIsAProfileToo() throws {
        let chosen = home.appendingPathComponent("elsewhere/profile")
        try write(#"{"oauthAccount":{}}"#, to: chosen.appendingPathComponent(".claude.json"))
        defaults.set(chosen.path, forKey: ClaudePaths.directoryPreference)
        XCTAssertEqual(sources().last?.folder.lastPathComponent, "profile")
    }

    func testAppFolderNames() {
        for name in ["Claude", "claude", "Claude-2", "Claude Work", "CLAUDE-Account-B"] {
            XCTAssertTrue(ClaudeAccountDiscovery.isAppFolderName(name), name)
        }
        for name in ["ClaudeUsageBar", "Claude.app", "Slack", "Claudette"] {
            XCTAssertFalse(ClaudeAccountDiscovery.isAppFolderName(name), name)
        }
    }
}
