import AppKit
import FrogAgent
import FrogCore
import XCTest
@testable import FrogApp

/// `frog plugins …` against an isolated model: the way an AI agent builds, installs, checks and packs a plugin.
@MainActor final class AgentPluginCommandsTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-plugin-commands-\(UUID().uuidString)", isDirectory: true)
        try ConfigurationStore(directory: directory).save(Configuration())
        model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil }, writeClipboard: { _ in },
                         toolkit: Toolkit(showsUsageStatusItem: false, showsMenuBarOrganizer: false))
        model.plugins.directoryURL = nil
        model.plugins.trash = { try FileManager.default.removeItem(at: $0) }
    }

    override func tearDown() async throws {
        model.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(_ words: String..., json: Bool = false) async -> AgentResponse {
        await AgentCommands.run(AgentRequest(arguments: words, json: json, directory: directory.path), model: model)
    }

    private func object(_ response: AgentResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.output.utf8)) as? [String: Any], response.output + response.error)
    }

    private func enablePlugins() async throws {
        try await model.setFeature(.plugins, enabled: true)
        model.plugins.configure(enabled: true)
    }

    func testTheGuideIsTheDocumentedReference() async throws {
        let guide = await run("plugins", "guide")
        XCTAssertEqual(guide.exitCode, 0, guide.error)
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/plugins.md")
        XCTAssertEqual(guide.output, try String(contentsOf: docs, encoding: .utf8),
                       "native/FrogApp/Resources/plugin-guide.md is a copy of docs/plugins.md; copy it again after changing either.")
        for command in AgentCommands.plugins {
            XCTAssertTrue(guide.output.contains(command.words.joined(separator: " ")), "The guide does not name `\(command.usage)`")
        }
    }

    func testAnAgentBuildsInstallsAndPacksAPluginButCannotApproveIt() async throws {
        let folder = directory.appendingPathComponent("tally", isDirectory: true)
        let off = await run("plugins", "install", folder.path)
        XCTAssertEqual(off.error, "Plugins is off. Turn it on with `frog features enable plugins`.")
        try await enablePlugins()

        let started = await run("plugins", "new", "tally", "--name", "Tally", "--id", "com.example.tally")
        XCTAssertEqual(started.exitCode, 0, started.error)
        let again = await run("plugins", "new", "tally")
        XCTAssertEqual(again.exitCode, AgentExit.failure, "An existing plugin's folder is never overwritten")
        let badID = await run("plugins", "new", "other", "--id", "Not An ID")
        XCTAssertEqual(badID.exitCode, AgentExit.usage)

        let checked = try object(await run("plugins", "check", "tally", json: true))
        XCTAssertEqual(checked["id"] as? String, "com.example.tally")
        XCTAssertEqual(checked["hints"] as? [String], [], "The template follows its own guide")

        // The first install waits for the user, and nothing the agent runs approves it.
        let installed = try object(await run("plugins", "install", "tally", json: true))
        XCTAssertEqual(installed["state"] as? String, "needs-review")
        XCTAssertNotNil(model.plugins.review, "Frog shows the review to the user")
        let blocked = await run("plugins", "snapshot", "com.example.tally")
        XCTAssertEqual(blocked.error, "Tally waits for the user's review in Frog → Plugins.")
        let review = try XCTUnwrap(model.plugins.review)
        try model.plugins.approve(review)

        // An update that asks for nothing new runs at once.
        try Data("console.log('ready'); frog.on('command', (id) => console.log('ran ' + id));".utf8)
            .write(to: folder.appendingPathComponent("app.js"))
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("plugin.json"))) as? [String: Any])
        manifest["commands"] = [["id": "ping", "title": "Ping", "show": false]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("plugin.json"))
        let updated = try object(await run("plugins", "install", "tally", json: true))
        XCTAssertEqual(updated["state"] as? String, "on")

        let picture = directory.appendingPathComponent("tally.png")
        let snapshot = await run("plugins", "snapshot", "tally", "--output", picture.path)
        XCTAssertEqual(snapshot.exitCode, 0, snapshot.error)
        XCTAssertEqual(try Data(contentsOf: picture).prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "A PNG")
        let ran = await run("plugins", "run", "com.example.tally", "ping")
        XCTAssertEqual(ran.exitCode, 0, ran.error)
        var logs = ""
        for _ in 0..<50 where !logs.contains("ran ping") {
            logs = await run("plugins", "logs", "com.example.tally").output
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(logs.contains("ready") && logs.contains("ran ping"), logs)

        let list = await run("plugins", "list")
        XCTAssertTrue(list.output.contains("on") && list.output.contains("com.example.tally"), list.output)

        let inside = await run("plugins", "pack", "tally", "--output", "tally/tally.frogplugin")
        XCTAssertEqual(inside.exitCode, AgentExit.usage, "A file packed into the plugin's own folder would ship in its next version")
        let packed = try object(await run("plugins", "pack", "tally", json: true))
        let file = try XCTUnwrap(packed["path"] as? String)
        XCTAssertEqual(file, directory.appendingPathComponent("com.example.tally-1.0.0.frogplugin").path)
        XCTAssertEqual(packed["sha256"] as? String, PluginPackage.sha256(try Data(contentsOf: URL(fileURLWithPath: file))))
        let unpacked = try model.plugins.store.unpack(try Data(contentsOf: URL(fileURLWithPath: file)), in: directory.appendingPathComponent("unpacked"))
        XCTAssertEqual(unpacked.manifest.commands.map(\.id), ["ping"])

        let removed = await run("plugins", "remove", "Tally")
        XCTAssertEqual(removed.exitCode, 0, removed.error)
        XCTAssertNil(model.plugins.item("com.example.tally"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("plugin.json").path), "The source folder stays")
    }

    func testAPackedFileOpensItsReviewWithoutInstalling() async throws {
        try await enablePlugins()
        _ = await run("plugins", "new", "shared", "--id", "com.example.shared")
        let packed = try object(await run("plugins", "pack", "shared", json: true))
        let file = try XCTUnwrap(packed["path"] as? String)
        let opened = await run("plugins", "install", file)
        XCTAssertEqual(opened.exitCode, 0, opened.error)
        XCTAssertEqual(model.plugins.review?.installed, false)
        XCTAssertNil(model.plugins.item("com.example.shared"), "Nothing is installed before the user approves it")
    }
}
