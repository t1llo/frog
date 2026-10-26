import FrogAgent
import FrogCore
import XCTest
@testable import FrogApp

@MainActor final class AgentCommandsTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ConfigurationStore(directory: directory).save(Configuration())
        model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil })
    }

    override func tearDown() async throws {
        model.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(_ words: String..., json: Bool = false, input: String? = nil) async -> AgentResponse {
        await AgentCommands.run(AgentRequest(arguments: words, json: json, input: input), model: model)
    }

    func testHelpListsEveryCommandAndExplainsOne() async {
        let help = await run("help")
        XCTAssertEqual(help.exitCode, 0)
        for command in AgentCommands.all {
            XCTAssertTrue(help.output.contains(command.usage.dropFirst("frog ".count)), command.usage)
            XCTAssertFalse(command.summary.isEmpty, command.usage)
        }
        let one = await run("help", "features", "enable")
        XCTAssertTrue(one.output.hasPrefix("frog features enable <feature>"))
        let group = await run("features")
        XCTAssertTrue(group.output.contains("features list"))
        let json = await run("help", json: true)
        let entries = try? JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [[String: Any]]
        XCTAssertEqual(entries?.count, AgentCommands.all.count)
    }

    func testEveryCommandHasItsOwnWordsAndAKnownGroup() {
        let usages = AgentCommands.all.map { $0.words.joined(separator: " ") }
        XCTAssertEqual(usages.count, Set(usages).count, "Two commands share their words")
        for command in AgentCommands.all {
            XCTAssertNotNil(AgentCommands.groups[command.words[0]], "\(command.usage) has no help heading")
        }
    }

    func testUnknownWordsAndOptionsAreUsageErrors() async {
        let unknown = await run("teleport")
        XCTAssertEqual(unknown.exitCode, AgentExit.usage)
        XCTAssertTrue(unknown.error.contains("frog help"))
        let option = await run("features", "list", "--colour")
        XCTAssertEqual(option.exitCode, AgentExit.usage)
        let missing = await run("features", "enable")
        XCTAssertEqual(missing.exitCode, AgentExit.usage)
    }

    func testFeaturesCanBeListedAndSwitched() async throws {
        let enabled = await run("features", "enable", "scripts")
        XCTAssertEqual(enabled.exitCode, 0, enabled.error)
        XCTAssertTrue(model.configuration.preferences.featureEnabled(.scripts))
        XCTAssertTrue(try ConfigurationStore(directory: directory).load().preferences.featureEnabled(.scripts))
        let list = await run("features", "list", json: true)
        let features = try JSONSerialization.jsonObject(with: Data(list.output.utf8)) as? [[String: Any]]
        XCTAssertEqual(features?.first { $0["id"] as? String == "scripts" }?["on"] as? Bool, true)
        XCTAssertEqual(features?.count, FeatureID.allCases.count)
        _ = await run("features", "disable", "Scripts")
        XCTAssertFalse(model.configuration.preferences.featureEnabled(.scripts))
        let unknown = await run("features", "enable", "teleporter")
        XCTAssertEqual(unknown.exitCode, AgentExit.usage)
    }

    func testFeatureNamesRoundTrip() {
        for feature in FeatureID.allCases {
            XCTAssertEqual(FeatureID.agentNamed(feature.agentName), feature)
            XCTAssertEqual(FeatureID.agentNamed(feature.rawValue), feature)
            XCTAssertEqual(FeatureID.agentNamed(feature.title), feature)
            XCTAssertFalse(feature.agentName.contains(where: \.isUppercase))
        }
        XCTAssertEqual(FeatureID.windowSwitcher.agentName, "window-switcher")
        XCTAssertEqual(FeatureID.scratchpad.agentName, "notes")
    }

    func testOptionsFlagsAndPositionalWordsAreSplit() throws {
        let command = AgentCommand(words: ["x"], summary: "x", options: ["app", "limit"], flags: ["all"]) { _ in .done("") }
        let parsed = try AgentCommands.parse(["one", "--app", "Safari", "--all", "--limit=3", "--", "--two"], for: command)
        XCTAssertEqual(parsed.positional, ["one", "--two"])
        XCTAssertEqual(parsed.options, ["app": "Safari", "limit": "3"])
        XCTAssertEqual(parsed.flags, ["all"])
        XCTAssertThrowsError(try AgentCommands.parse(["--app"], for: command))
    }

    func testStatusAnswersInTextAndJSON() async throws {
        let text = await run("status")
        XCTAssertTrue(text.output.contains("Accessibility"))
        let json = await run("status", json: true)
        let status = try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any]
        XCTAssertNotNil(status?["featuresOn"])
    }

    func testTheServerAnswersOverItsSocketOnlyWhileAccessIsOn() async throws {
        let socket = URL(fileURLWithPath: "/tmp/frog-\(UUID().uuidString.prefix(8)).sock")
        let server = AgentServer(socket: socket) { [model] request in await AgentCommands.run(request, model: model!) }
        server.configure(enabled: true)
        XCTAssertTrue(server.isListening, server.issue ?? "")
        let response = try await Task.detached { try AgentClient.send(AgentRequest(arguments: ["version"]), to: socket, timeout: 10) }.value
        XCTAssertEqual(response.exitCode, 0)
        server.configure(enabled: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
    }
}
