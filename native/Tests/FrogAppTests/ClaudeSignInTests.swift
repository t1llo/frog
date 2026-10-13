import XCTest
@testable import FrogApp

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
}
