import AppKit
import FrogAgent
import FrogCore
import FrogTestSupport
import FrogUsage
import XCTest
@testable import FrogApp

/// The `frog` tool's commands for Frog's tools, against an isolated model: a temporary data folder, a
/// pasteboard of its own, a pretend power setting and a pretend model.
@MainActor final class AgentToolCommandsTests: XCTestCase {
    private var directory: URL!
    private var pasteboard: NSPasteboard!
    private var power: PretendPower!
    private var model: AppModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ConfigurationStore(directory: directory).save(Configuration())
        pasteboard = NSPasteboard.withUniqueName()
        power = PretendPower()
        let usage = UsageDashboardModel(defaults: temporaryDefaults(), fixtureRoot: directory.appendingPathComponent("fixtures"))
        model = AppModel(dataDirectory: directory, registerShortcuts: false,
                         complete: { text, _, _, _ in
                             // "slow" keeps the pretend model busy until the run is cancelled.
                             if text == "slow" { try await Task.sleep(for: .seconds(30)) }
                             return "Fixed: \(text)"
                         }, readKey: { _ in nil },
                         writeClipboard: { _ in XCTFail("The frog tool never copies a rule's result") },
                         powerController: StayAwakeController(system: power, directory: directory),
                         toolkit: Toolkit(makeUsage: { usage }, showsUsageStatusItem: false),
                         clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate()))
    }

    override func tearDown() async throws {
        model.shutdown()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(_ words: String..., json: Bool = false, input: String? = nil) async -> AgentResponse {
        await AgentCommands.run(AgentRequest(arguments: words, json: json, directory: directory.path, input: input), model: model)
    }

    private func object(_ response: AgentResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.output.utf8)) as? [String: Any], response.output)
    }

    private func array(_ response: AgentResponse) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.output.utf8)) as? [[String: Any]], response.output)
    }

    private func enable(_ features: FeatureID...) async throws {
        for feature in features { try await model.setFeature(feature, enabled: true) }
    }

    func testCommandsOfRetiredFeaturesSayWhatToUseInstead() async {
        let snippets = await run("snippets", "list")
        XCTAssertEqual(snippets.exitCode, AgentExit.usage)
        XCTAssertTrue(snippets.error.contains("frog run notes.list"), snippets.error)
        let shelf = await run("shelf", "add", "report.pdf")
        XCTAssertEqual(shelf.exitCode, AgentExit.usage)
        XCTAssertTrue(shelf.error.contains("notes now"), shelf.error)
    }

    func testClipboardListHidesSensitiveTextAndCopyWritesThePasteboard() async throws {
        try await enable(.clipboard)
        let history = model.clipboardHistoryStore
        history.configure(enabled: true, automaticallyPoll: false)
        history.recordCopiedText("Visible text")
        XCTAssertTrue(ClipboardHistoryEntry(text: "hunter2", isSensitive: true).write(to: pasteboard, plainText: true))
        await history.poll()
        XCTAssertEqual(history.entries.count, 2)

        let text = await run("clipboard", "list")
        XCTAssertTrue(text.output.contains("Visible text") && text.output.contains("Sensitive text, hidden"), text.output)
        let json = await run("clipboard", "list", json: true)
        XCTAssertFalse(text.output.contains("hunter2") || json.output.contains("hunter2"))
        let items = try array(json)
        XCTAssertEqual(items.first?["sensitive"] as? Bool, true)
        XCTAssertNil(items.first?["text"])
        let limited = try array(await run("clipboard", "list", "--limit", "1", json: true))
        XCTAssertEqual(limited.count, 1)

        let copied = await run("clipboard", "copy", "See", "you", "at", "10")
        XCTAssertEqual(copied.exitCode, 0, copied.error)
        XCTAssertEqual(pasteboard.string(forType: .string), "See you at 10")
        XCTAssertEqual(history.entries.first?.text, "See you at 10")
        let empty = await run("clipboard", "copy")
        XCTAssertEqual(empty.exitCode, AgentExit.usage)
    }

    func testRulesAreListedAndRunOnTextWithoutCopying() async throws {
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
        var preferences = model.configuration.preferences
        preferences.historyEnabled = true
        try model.savePreferences(preferences)

        let list = await run("rules", "list")
        XCTAssertTrue(list.output.contains("Proofread"), list.output)
        let result = await run("rules", "run", "proofread", "teh", "text")
        XCTAssertEqual(result.exitCode, 0, result.error)
        XCTAssertEqual(result.output, "Fixed: teh text")
        XCTAssertEqual(model.history.first?.processedText, "Fixed: teh text", "History keeps the run while it is on")
        let piped = try object(await run("rules", "run", "Proofread", json: true, input: "a b"))
        XCTAssertEqual(piped["result"] as? String, "Fixed: a b")
        XCTAssertEqual(model.manualResult, "", "The Writing page's Try shows only its own runs")
        let unknown = await run("rules", "run", "Shout", "x")
        XCTAssertEqual(unknown.exitCode, AgentExit.usage)
    }

    func testARuleResultIsKeptWhenHistoryCannotSaveIt() async throws {
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
        var preferences = model.configuration.preferences
        preferences.historyEnabled = true
        try model.savePreferences(preferences)
        // A folder where History's file belongs makes saving it fail.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("history.json"), withIntermediateDirectories: true)

        let result = await run("rules", "run", "Proofread", "teh")
        XCTAssertEqual(result.exitCode, 0, result.error)
        XCTAssertEqual(result.output, "Fixed: teh")
        XCTAssertTrue(result.error.contains("history could not be saved"), result.error)
    }

    func testARuleRunEndsWithItsCommandAndAShortcutPressMeanwhileIsAnswered() async throws {
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
        let rule = try XCTUnwrap(model.configuration.rules.first { $0.name == "Proofread" })
        let running = Task { await self.run("rules", "run", "Proofread", "slow") }
        for _ in 0..<200 where !model.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.isProcessing)

        model.processSelection(ruleID: rule.id)
        XCTAssertTrue(model.errorMessage?.contains("An agent is running a rule") == true, model.errorMessage ?? "no message")

        running.cancel()
        let response = await running.value
        XCTAssertEqual(response.exitCode, AgentExit.failure)
        XCTAssertTrue(response.error.contains("cancelled"), response.error)
        XCTAssertFalse(model.isProcessing)
    }

    func testStayAwakeHoldsTheMacAwakeWithoutTouchingTheSleepSetting() async throws {
        await model.pluginHost.syncAndWait()
        let status = try object(await run("awake", "status", json: true))
        XCTAssertEqual(status["on"] as? Bool, false)
        XCTAssertEqual(status["lidClosed"] as? Bool, false)
        let text = await run("awake", "status")
        XCTAssertEqual(text.output, "Off")

        let on = await run("awake", "on", "--for", "1h")
        XCTAssertEqual(on.exitCode, 0, on.error)
        XCTAssertTrue(on.output.hasPrefix("On until"), on.output)
        XCTAssertEqual(model.power.duration, .untilOff, "--for leaves the page's own choice alone")
        let deadline = try XCTUnwrap(model.power.deadline)
        XCTAssertEqual(deadline.timeIntervalSinceNow, 3600, accuracy: 60)
        let onStatus = try object(await run("awake", "status", json: true))
        XCTAssertNotNil(onStatus["until"])
        let longer = await run("run", "stay-awake.on", "--for", "90")
        XCTAssertEqual(longer.exitCode, 0, longer.error)
        XCTAssertEqual(try XCTUnwrap(model.power.deadline).timeIntervalSinceNow, 5400, accuracy: 60)
        let off = await run("awake", "off")
        XCTAssertEqual(off.output, "Off")
        XCTAssertFalse(model.power.isEnabled)
        let writes = await power.writes
        XCTAssertEqual(writes, [], "Only the lid-closed mode changes the sleep setting")

        let wrong = await run("awake", "on", "--for", "soon")
        XCTAssertNotEqual(wrong.exitCode, 0)
        XCTAssertTrue(wrong.error.contains("--for"), wrong.error)
        XCTAssertFalse(model.power.isEnabled)
    }

    func testUsageListsEachProvider() async throws {
        try await enable(.usage)
        // The test model is never started, so the plugin starts here rather than at launch.
        await model.pluginHost.syncAndWait()
        let response = await run("usage", json: true)
        XCTAssertEqual(response.exitCode, 0, response.error)
        let providers = try array(response)
        XCTAssertEqual(providers.compactMap { $0["provider"] as? String }, ["Claude", "OpenAI"])
        let text = await run("usage")
        XCTAssertTrue(text.output.contains("Claude") && text.output.contains("OpenAI"), text.output)
    }

    func testMonitorTakesOneReading() async throws {
        let reading = try object(await run("monitor", json: true))
        XCTAssertGreaterThan(((reading["memory"] as? [String: Any])?["totalBytes"] as? Int) ?? 0, 0)
        XCTAssertNotNil(reading["powerSource"])
        XCTAssertNil(reading["disk"], "Disk is no longer read")
        let text = await run("monitor")
        let total = ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
        XCTAssertTrue(text.output.contains("of \(total)"), "Memory as macOS shows it: \(text.output)")
    }

    func testCommandsOfAFeatureThatIsOffSayHowToTurnItOn() async throws {
        let cases: [([String], String)] = [
            (["clipboard", "list"], "clipboard"), (["usage"], "usage")
        ]
        for (words, feature) in cases {
            let response = await AgentCommands.run(AgentRequest(arguments: words), model: model)
            XCTAssertEqual(response.exitCode, AgentExit.failure, words.joined(separator: " "))
            XCTAssertTrue(response.error.contains("frog features enable \(feature)"), response.error)
        }
        try await model.setFeature(.stayAwake, enabled: false)
        try await model.setFeature(.writing, enabled: false)
        let awake = await run("awake", "status")
        XCTAssertTrue(awake.error.contains("frog features enable stay-awake"), awake.error)
        let rules = await run("rules", "list")
        XCTAssertTrue(rules.error.contains("frog features enable writing"), rules.error)
    }

    func testHelpListsAndExplainsTheToolCommands() async {
        let help = await run("help")
        for usage in ["clipboard list [--limit N]", "rules run <rule> <text>", "awake on", "monitor", "usage"] {
            XCTAssertTrue(help.output.contains(usage), usage)
        }
    }
}

/// The sleep setting, kept in memory: these tests never change the Mac's.
private actor PretendPower: StayAwakeSystem {
    private var disabled = false
    private var denied = false
    private(set) var writes: [Bool] = []
    func deny() { denied = true }
    func hasAccess() async throws -> Bool { !denied }
    func sleepDisabled() async throws -> Bool { disabled }
    func battery() async throws -> PowerBattery { PowerBattery(onBattery: false, percent: 80) }
    func setSleepDisabled(_ value: Bool) async throws {
        writes.append(value)
        if denied { throw StayAwakeError.permission }
        disabled = value
    }
}
