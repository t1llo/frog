import XCTest
@testable import FrogApp

/// The installer works on a temporary home folder and a fake Frog.app; nothing touches the real ones.
final class AgentInstallerTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var installer: AgentInstaller!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        installer = AgentInstaller(home: home, app: try fakeApp("Frog.app"), commandFolders: [home.appendingPathComponent("bin")])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func fakeApp(_ name: String) throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        let helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let tool = helpers.appendingPathComponent("frog")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return app
    }

    private func write(_ text: String, to relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ relative: String) -> String? {
        try? String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: The frog command

    func testToolInstallsAsALinkAndRemoves() throws {
        XCTAssertEqual(installer.toolState(), .notInstalled)
        try installer.installTool()
        XCTAssertEqual(installer.toolState(), .installed)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: installer.linkURL.path)
        XCTAssertEqual(destination, installer.helperURL.path)
        try installer.installTool()
        XCTAssertEqual(installer.toolState(), .installed, "Installing twice changes nothing")
        try installer.removeTool()
        XCTAssertEqual(installer.toolState(), .notInstalled)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.helperURL.path), "Removing the link keeps the tool")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installer.linkURL.deletingLastPathComponent().path), [])
    }

    func testALinkToAnotherFrogCanBeRelinkedOrRemoved() throws {
        let other = AgentInstaller(home: home, app: try fakeApp("Old Frog.app"))
        try other.installTool()
        guard case .otherCopy(let path) = installer.toolState() else { return XCTFail("\(installer.toolState())") }
        XCTAssertEqual(path, other.helperURL.path)
        try installer.installTool()
        XCTAssertEqual(installer.toolState(), .installed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installer.linkURL.path), installer.helperURL.path)

        // A link left behind by a copy that was deleted still counts as Frog's.
        try other.installTool()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Old Frog.app"))
        guard case .otherCopy = installer.toolState() else { return XCTFail("\(installer.toolState())") }
        try installer.removeTool()
        XCTAssertEqual(installer.toolState(), .notInstalled)
    }

    func testAFileFrogDidNotMakeIsNeverReplaced() throws {
        try write("#!/bin/sh\necho mine\n", to: ".local/bin/frog")
        XCTAssertEqual(installer.toolState(), .blocked)
        XCTAssertThrowsError(try installer.installTool())
        XCTAssertThrowsError(try installer.removeTool())
        XCTAssertEqual(read(".local/bin/frog"), "#!/bin/sh\necho mine\n")

        // Nor is a link to something else, even a broken one.
        try FileManager.default.removeItem(at: installer.linkURL)
        try FileManager.default.createSymbolicLink(atPath: installer.linkURL.path, withDestinationPath: "/nowhere/frog-cli")
        XCTAssertEqual(installer.toolState(), .blocked)
        XCTAssertThrowsError(try installer.installTool())
        XCTAssertThrowsError(try installer.removeTool())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installer.linkURL.path), "/nowhere/frog-cli")
    }

    func testToolIsUnavailableWithoutTheAppsHelper() throws {
        let bare = AgentInstaller(home: home, app: root.appendingPathComponent("debug", isDirectory: true))
        guard case .unavailable(let reason) = bare.toolState() else { return XCTFail("\(bare.toolState())") }
        XCTAssertTrue(reason.contains("ships with the Frog app"), reason)
        XCTAssertThrowsError(try bare.installTool())
        XCTAssertFalse(FileManager.default.fileExists(atPath: bare.linkURL.deletingLastPathComponent().path))
        let moved = AgentInstaller(home: home, app: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Frog.app"))
        XCTAssertEqual(moved.toolState(), .unavailable("Move Frog to Applications first."))
    }

    func testShellPathHint() throws {
        XCTAssertFalse(installer.shellFindsLocalBin())
        try write("export PATH=\"$HOME/.local/bin:$PATH\"\n", to: ".zshrc")
        XCTAssertTrue(installer.shellFindsLocalBin())
        XCTAssertEqual(AgentInstaller.pathLine(shell: "/bin/zsh").file, "~/.zshrc")
        XCTAssertEqual(AgentInstaller.pathLine(shell: "/opt/homebrew/bin/fish").line, "fish_add_path ~/.local/bin")
        XCTAssertEqual(AgentInstaller.pathLine(shell: "/bin/bash").file, "~/.bash_profile")
    }

    // MARK: Skills

    func testSkillInstallsWhereEachAgentReadsIt() throws {
        for folder in AgentInstaller.skillFolders {
            XCTAssertEqual(installer.skillState(folder), .notInstalled)
            try installer.installSkill(folder)
            XCTAssertEqual(installer.skillState(folder), .installed)
        }
        XCTAssertEqual(read(".claude/skills/frog/SKILL.md"), AgentSkill.text)
        XCTAssertEqual(read(".agents/skills/frog/SKILL.md"), AgentSkill.text)
        // Every agent is served by exactly one folder.
        XCTAssertEqual(AgentInstaller.skillFolders.flatMap(\.agents).sorted { $0.rawValue < $1.rawValue },
                       CodingAgent.allCases.sorted { $0.rawValue < $1.rawValue })
    }

    func testSkillFollowsTheAgentSkillsFormat() throws {
        let text = AgentSkill.text
        XCTAssertTrue(text.hasPrefix("---\nname: frog\ndescription: "))
        let frontmatter = try XCTUnwrap(text.dropFirst(4).components(separatedBy: "\n---\n").first)
        let description = try XCTUnwrap(frontmatter.split(separator: "\n").first { $0.hasPrefix("description: ") }).dropFirst("description: ".count)
        XCTAssertLessThanOrEqual(description.count, 1024)
        XCTAssertFalse(description.contains(": "), "A plain YAML value cannot hold “: ”")
        XCTAssertEqual(AgentSkill.installedVersion(of: text), AgentSkill.version)
        XCTAssertNotNil(AgentSkill.name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression))
        for needed in ["frog help", "--json", "--stdin", "69", "Settings → Agents", "/Applications/Frog.app/Contents/Helpers/frog"] {
            XCTAssertTrue(text.contains(needed), needed)
        }
    }

    func testAnOlderSkillCanBeUpdated() throws {
        let folder = AgentInstaller.skillFolders[1]
        let older = AgentSkill.text.replacingOccurrences(of: "\(AgentSkill.marker): \"\(AgentSkill.version)\"",
                                                         with: "\(AgentSkill.marker): \"\(AgentSkill.version - 1)\"")
        XCTAssertNotEqual(older, AgentSkill.text)
        try write(older, to: ".agents/skills/frog/SKILL.md")
        XCTAssertEqual(installer.skillState(folder), .outdated)
        try installer.installSkill(folder)
        XCTAssertEqual(installer.skillState(folder), .installed)
        XCTAssertEqual(read(".agents/skills/frog/SKILL.md"), AgentSkill.text)

        // A newer Frog's skill is left as it is.
        let newer = AgentSkill.text.replacingOccurrences(of: "\(AgentSkill.marker): \"\(AgentSkill.version)\"",
                                                         with: "\(AgentSkill.marker): \"\(AgentSkill.version + 1)\"")
        try write(newer, to: ".agents/skills/frog/SKILL.md")
        XCTAssertEqual(installer.skillState(folder), .installed)
    }

    func testASkillFrogDidNotWriteIsNeverReplaced() throws {
        let folder = AgentInstaller.skillFolders[0]
        let theirs = "---\nname: frog\ndescription: Someone else's frog.\n---\nRibbit.\n"
        try write(theirs, to: ".claude/skills/frog/SKILL.md")
        XCTAssertEqual(installer.skillState(folder), .blocked)
        XCTAssertThrowsError(try installer.installSkill(folder))
        XCTAssertThrowsError(try installer.removeSkill(folder))
        XCTAssertEqual(read(".claude/skills/frog/SKILL.md"), theirs)

        // A file where the folder would go is someone else's too.
        try FileManager.default.removeItem(at: installer.skillFolderURL(folder))
        try write("notes", to: ".claude/skills/frog")
        XCTAssertEqual(installer.skillState(folder), .blocked)
        XCTAssertThrowsError(try installer.installSkill(folder))
        XCTAssertEqual(read(".claude/skills/frog"), "notes")
    }

    func testRemovingTheSkillLeavesOtherFilesAndSkillsAlone() throws {
        let folder = AgentInstaller.skillFolders[1]
        try write("---\nname: other\ndescription: Another skill.\n---\n", to: ".agents/skills/other/SKILL.md")
        try installer.installSkill(folder)
        try write("my notes", to: ".agents/skills/frog/notes.md")
        try installer.removeSkill(folder)
        XCTAssertEqual(installer.skillState(folder), .notInstalled)
        XCTAssertNil(read(".agents/skills/frog/SKILL.md"))
        XCTAssertEqual(read(".agents/skills/frog/notes.md"), "my notes", "A file Frog did not write stays, and so does its folder")
        XCTAssertNotNil(read(".agents/skills/other/SKILL.md"))

        try FileManager.default.removeItem(at: home.appendingPathComponent(".agents/skills/frog/notes.md"))
        try installer.installSkill(folder)
        try installer.removeSkill(folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.skillFolderURL(folder).path), "An empty frog folder goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents/skills").path))
        XCTAssertNoThrow(try installer.removeSkill(folder), "Removing what is not there is fine")
    }

    // MARK: Agents on this Mac

    func testAgentsAreFoundByTheirFoldersOrCommands() throws {
        XCTAssertEqual(installer.detectedAgents(), [])
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/opencode"), withIntermediateDirectories: true)
        try write("#!/bin/sh\n", to: "bin/claude")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent("bin/claude").path)
        XCTAssertEqual(installer.detectedAgents(), [.codex, .openCode, .claudeCode])
    }
}
