import XCTest
import FrogCore
@testable import FrogApp

/// The Writing, Explain and History actions as `frog run` calls them, on an isolated model with fake models.
@MainActor
final class WritePluginActionsTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!
    private var completed: [(text: String, rule: String)] = []
    private var answered: [AnswerRequest] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = AppModel(dataDirectory: directory, registerShortcuts: false,
                         complete: { [weak self] text, rule, _, _ in
                             self?.completed.append((text, rule.name)); return "Rewritten: \(text)"
                         },
                         readKey: { _ in nil }, writeClipboard: { _ in }, readAccessibility: { true },
                         answerStream: { [weak self] request in
                             self?.answered.append(request)
                             return AsyncThrowingStream { $0.yield(.text("It means the same either way.")); $0.finish() }
                         },
                         systemStatusTick: { try await Task.sleep(for: .seconds(3_600)) })
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
        model.start()
        await model.pluginHost.syncAndWait()
    }

    override func tearDown() async throws {
        model.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(_ id: String, _ values: [String: String] = [:], text: String? = nil) async throws -> ActionResult {
        try await model.pluginHost.run(id, ActionInput(values: values, text: text, source: .agent))
    }

    private var writing: WritingPlugin { model.pluginHost.running["writing"] as! WritingPlugin }

    func testWritingListsItsRulesAndRunsOneOnStandardInput() async throws {
        let rules = writing.rules
        XCTAssertFalse(rules.isEmpty)
        let list = try await run("writing.list")
        let listed = try JSONSerialization.jsonObject(with: Data(list.json.utf8)) as? [[String: Any]]
        XCTAssertEqual(listed?.map { $0["name"] as? String }, rules.map(\.name))
        XCTAssertEqual(listed?.first?["then"] as? String, "replace")

        let rule = try XCTUnwrap(rules.first { $0.enabled })
        let result = try await run("writing.run", ["rule": WritingPlugin.slug(rule.name)], text: "teh text")
        XCTAssertEqual(result.text, "Rewritten: teh text")
        XCTAssertEqual(completed.map(\.rule), [rule.name])

        do {
            _ = try await run("writing.run", ["rule": WritingPlugin.slug(rule.name)])
            XCTFail("Ran without text")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("standard input"), error.localizedDescription)
        }
    }

    func testRulesRunByDisplayNameSayWhenTheyAreOffAndClashingNamesAreReported() async throws {
        var rule = try XCTUnwrap(writing.rules.first { $0.enabled })
        let result = try await run("writing.run", ["rule": rule.name.uppercased()], text: "teh")
        XCTAssertEqual(result.text, "Rewritten: teh")
        rule.enabled = false
        try model.saveRule(rule)
        do {
            _ = try await run("writing.run", ["rule": rule.name], text: "teh")
            XCTFail("Ran a rule that is off")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("is off"), error.localizedDescription)
        }

        var twin = model.configuration.newRule(category: .text, installed: [])
        twin.name = rule.name + "!"
        try model.saveRule(twin)
        let list = try await run("writing.list")
        XCTAssertTrue(list.text.contains("Several rules are called “\(WritingPlugin.slug(rule.name))”"), list.text)
        let listed = try JSONSerialization.jsonObject(with: Data(list.json.utf8)) as? [[String: Any]]
        XCTAssertEqual(listed?.filter { $0["clashes"] as? Bool == true }.count, 2)
        do {
            _ = try await run("writing.run", ["rule": rule.name], text: "teh")
            XCTFail("Ran one of two rules with the same name")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Several"), error.localizedDescription)
        }
    }

    func testAShowRuleAnswersInsteadOfRewriting() async throws {
        var define = model.configuration.newRule(category: .text, installed: [])
        define.name = "Define"; define.instructions = "Define the term."
        define.action?.textOutput = .panel; define.providerID = model.configuration.providers[0].id
        try model.saveRule(define)
        XCTAssertTrue(writing.rules.contains { $0.id == define.id }, "a custom Show rule is a Writing rule")
        let result = try await run("writing.run", ["rule": "define"], text: "idempotent")
        XCTAssertEqual(result.text, "It means the same either way.")
        XCTAssertTrue(completed.isEmpty)
        XCTAssertEqual(answered.count, 1)
    }

    func testTheBubbleActionSwitchesItAndSavesTheTable() async throws {
        XCTAssertFalse(writing.settings.bubble.on)
        _ = try await run("writing.bubble")
        XCTAssertTrue(writing.settings.bubble.on)
        XCTAssertTrue(model.offersBubbleChoice)
        _ = try await run("writing.bubble", ["on": "false"])
        XCTAssertFalse(writing.settings.bubble.on)
        XCTAssertEqual(try model.settingsFile.section("writing", as: WritingConfig.self).value.bubble.on, false)
    }

    func testExplainAnswersTextWithContextOnlyWhileContextIsOn() async throws {
        try await model.setFeature(.explain, enabled: true)
        await model.pluginHost.syncAndWait()
        let rule = try XCTUnwrap(model.configuration.rules.first(where: \.isExplainRule))
        var explain = rule; explain.providerID = model.configuration.providers[0].id
        try model.saveRule(explain)

        let result = try await run("explain.text", ["context": "The levee held all night."], text: "levee")
        XCTAssertEqual(result.text, "It means the same either way.")
        XCTAssertTrue(try XCTUnwrap(answered.last?.messages.first?.text).contains("The levee held all night."))

        let plugin = try XCTUnwrap(model.pluginHost.running["explain"] as? ExplainPlugin)
        var settings = plugin.settings; settings.context = false
        try plugin.save(settings)
        _ = try await run("explain.text", ["context": "The levee held all night."], text: "levee")
        XCTAssertFalse(try XCTUnwrap(answered.last?.messages.first?.text).contains("The levee held all night."))
    }

    func testHistoryListsSearchesAndClearsWhatRulesSaved() async throws {
        var preferences = model.configuration.preferences
        preferences.historyEnabled = true
        try model.savePreferences(preferences)
        let rule = try XCTUnwrap(writing.rules.first { $0.enabled })
        _ = try await run("writing.run", ["rule": WritingPlugin.slug(rule.name)], text: "first note")
        _ = try await run("writing.run", ["rule": WritingPlugin.slug(rule.name)], text: "second draft")

        let all = try await run("history.list")
        let listed = try JSONSerialization.jsonObject(with: Data(all.json.utf8)) as? [[String: Any]]
        XCTAssertEqual(listed?.count, 2)
        XCTAssertEqual(listed?.first?["result"] as? String, "Rewritten: second draft", "newest first")
        let found = try await run("history.list", ["search": "first", "limit": "5"])
        XCTAssertTrue(found.text.contains("Rewritten: first note"))
        XCTAssertFalse(found.text.contains("second"))

        let id = try XCTUnwrap(listed?.last?["id"] as? String)
        _ = try await run("history.delete", ["id": id])
        XCTAssertEqual(model.history.count, 1)
        let cleared = try await run("history.clear")
        XCTAssertEqual(cleared.text, "Deleted 1 entry.")
        XCTAssertTrue(model.history.isEmpty)
    }
}
