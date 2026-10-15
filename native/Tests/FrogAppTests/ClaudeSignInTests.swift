import XCTest
@testable import FrogApp
@testable import FrogUsage

final class ClaudeSignInTests: XCTestCase {
    func testLauncherIsAPrivateTerminalProfileThatRunsOnlyTheSignIn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-sign-in-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let command = "exec '/Users/someone/.local/bin/claude' 'auth' 'login'"
        let launcher = try ClaudeSignIn.launcher(command: command, directory: directory)
        XCTAssertEqual(launcher.pathExtension, "terminal")
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: launcher), format: nil) as? [String: Any])
        XCTAssertEqual(profile["CommandString"] as? String, command)
        XCTAssertEqual(profile["RunCommandAsShell"] as? Bool, false)
        XCTAssertEqual(profile["shellExitAction"] as? Int, 1, "The window stays open when signing in fails")
        let folder = try FileManager.default.attributesOfItem(atPath: launcher.deletingLastPathComponent().path)
        XCTAssertEqual(folder[.posixPermissions] as? Int, 0o700)
        // Asking twice reuses the same file instead of leaving copies behind.
        XCTAssertEqual(try ClaudeSignIn.launcher(command: command, directory: directory), launcher)
    }

    func testTheLiveSetupCommandForAnotherAccountRunsUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-sign-in-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let home = URL(fileURLWithPath: "/Users/some one")
        let command = ClaudeCodeCLI.signInCommand(executable: home.appendingPathComponent(".local/bin/claude"),
                                                  directory: ClaudeAccountsModel.liveSetupFolder(for: URL(fileURLWithPath: "/x/Claude-Account-B"), home: home))
        XCTAssertEqual(command, "exec '/usr/bin/env' 'CLAUDE_CONFIG_DIR=/Users/some one/.claude-account-b' '/Users/some one/.local/bin/claude' 'auth' 'login'")
        let launcher = try ClaudeSignIn.launcher(command: command, directory: directory)
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: launcher), format: nil) as? [String: Any])
        XCTAssertEqual(profile["CommandString"] as? String, command)
    }
}
