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
                         complete: { text, _, _, _ in "Fixed: \(text)" }, readKey: { _ in nil },
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

    private func store(_ items: UtilityDocument...) async {
        await model.documents.load()
        items.forEach { model.documents.add($0) }
        _ = await model.documents.flush()
    }

    func testNotesCanBeAddedListedShownAndAppendedTo() async throws {
        try await enable(.scratchpad)
        let added = await run("notes", "add", "Groceries", "Milk")
        XCTAssertEqual(added.exitCode, 0, added.error)
        let again = await run("notes", "add", "Groceries")
        XCTAssertEqual(again.exitCode, AgentExit.failure, "A second note with the same title would make the name ambiguous")
        _ = await run("notes", "add", "Plan A", input: "From standard input")
        _ = await run("notes", "add", "Plan B", "--text", "Second")

        let list = await run("notes", "list")
        XCTAssertTrue(list.output.contains("Groceries") && list.output.contains("Plan B"), list.output)
        let shown = await run("notes", "show", "groc")
        XCTAssertEqual(shown.output, "Milk", "A unique start of the name in any case is enough")
        let appended = await run("notes", "append", "Groceries", "Bread", "and", "butter")
        XCTAssertEqual(appended.exitCode, 0, appended.error)
        let json = try object(await run("notes", "show", "Groceries", json: true))
        XCTAssertEqual(json["text"] as? String, "Milk\nBread and butter")
        let piped = await run("notes", "show", "Plan A")
        XCTAssertEqual(piped.output, "From standard input")

        let ambiguous = await run("notes", "show", "plan")
        XCTAssertEqual(ambiguous.exitCode, AgentExit.usage)
        XCTAssertTrue(ambiguous.error.contains("Plan A") && ambiguous.error.contains("Plan B"), ambiguous.error)
        let missing = await run("notes", "show", "Holiday")
        XCTAssertEqual(missing.exitCode, AgentExit.usage)
        XCTAssertTrue(missing.error.contains("frog notes list"), missing.error)

        let saved = try await UtilityDocumentStore(directory: directory.appendingPathComponent("Toolkit")).load()
        XCTAssertEqual(saved.first { $0.title == "Groceries" }?.text, "Milk\nBread and butter", "Each change is on disk when the command answers")
        XCTAssertEqual(saved.filter { $0.kind == .note }.count, 3)
    }

    func testSnippetsShowTheirTextAndExpandItWithoutRevealingSensitiveText() async throws {
        try await enable(.snippets)
        await store(UtilityDocument(kind: .snippet, title: "Greeting", text: "Hi {{clipboard}}, {{date}}"))
        pasteboard.clearContents(); pasteboard.setString("Anna", forType: .string)

        let raw = await run("snippets", "show", "Greeting")
        XCTAssertEqual(raw.output, "Hi {{clipboard}}, {{date}}")
        let expanded = await run("snippets", "show", "greeting", "--expand")
        XCTAssertTrue(expanded.output.hasPrefix("Hi Anna, "), expanded.output)
        XCTAssertFalse(expanded.output.contains("{{"), expanded.output)
        let list = await run("snippets", "list")
        XCTAssertTrue(list.output.contains("Greeting"), list.output)

        XCTAssertTrue(ClipboardHistoryEntry(text: "hunter2", isSensitive: true).write(to: pasteboard, plainText: true))
        let concealed = await run("snippets", "show", "Greeting", "--expand")
        XCTAssertEqual(concealed.exitCode, AgentExit.failure)
        XCTAssertFalse(concealed.output.contains("hunter2") || concealed.error.contains("hunter2"))
    }

    func testScriptsRunAsTheAppRunsThemAndPassOnTheirExitCode() async throws {
        try await enable(.scripts)
        await store(UtilityDocument(kind: .script, title: "Hello", text: "echo hello"),
                    UtilityDocument(kind: .script, title: "Fails", text: "echo partial; exit 3"),
                    UtilityDocument(kind: .script, title: "Slow", text: "echo started; sleep 5"))

        let list = await run("scripts", "list")
        XCTAssertTrue(list.output.contains("echo partial; exit 3"), list.output)
        let shown = await run("scripts", "show", "hello")
        XCTAssertEqual(shown.output, "echo hello")

        let hello = await run("scripts", "run", "Hello")
        XCTAssertEqual(hello.exitCode, 0, hello.error)
        XCTAssertEqual(hello.output, "hello\n")
        let json = try object(await run("scripts", "run", "Hello", json: true))
        XCTAssertEqual(json["status"] as? Int, 0)
        XCTAssertEqual(json["output"] as? String, "hello\n")
        XCTAssertEqual(json["truncated"] as? Bool, false)

        let fails = await run("scripts", "run", "Fails")
        XCTAssertEqual(fails.exitCode, 3)
        XCTAssertEqual(fails.output, "partial\n")
        XCTAssertTrue(fails.error.contains("status 3"), fails.error)

        let slow = await run("scripts", "run", "Slow", "--timeout", "1")
        XCTAssertEqual(slow.exitCode, AgentExit.failure)
        XCTAssertTrue(slow.output.contains("started"), "What it printed before the time ran out: \(slow.output)")
        XCTAssertFalse(slow.error.isEmpty)
        let wrong = await run("scripts", "run", "Hello", "--timeout", "0")
        XCTAssertEqual(wrong.exitCode, AgentExit.usage)
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

    func testShelfTakesFilesAndLinksAndListsTheirPaths() async throws {
        try await enable(.shelf)
        let file = directory.appendingPathComponent("report.txt")
        try "report".write(to: file, atomically: true, encoding: .utf8)
        let added = await run("shelf", "add", "report.txt", "https://example.com/page")
        XCTAssertEqual(added.exitCode, 0, added.error)
        let items = try array(await run("shelf", "list", json: true))
        XCTAssertEqual(items.count, 2)
        let paths = items.compactMap { $0["files"] as? [String] }.flatMap { $0 }
        XCTAssertEqual(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }, [file.resolvingSymlinksInPath()])
        let list = await run("shelf", "list")
        XCTAssertTrue(list.output.contains("report.txt"), list.output)
        let missing = await run("shelf", "add", "nothing-here.txt")
        XCTAssertEqual(missing.exitCode, AgentExit.usage)
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
        let unknown = await run("rules", "run", "Shout", "x")
        XCTAssertEqual(unknown.exitCode, AgentExit.usage)
    }

    func testStayAwakeReportsAndSwitchesThePretendSetting() async throws {
        let status = try object(await run("awake", "status", json: true))
        XCTAssertEqual(status["on"] as? Bool, false)
        XCTAssertEqual(status["access"] as? String, "ready")
        let text = await run("awake", "status")
        XCTAssertTrue(text.output.contains("off"), text.output)

        let on = await run("awake", "on", "--for", "1h")
        XCTAssertEqual(on.exitCode, 0, on.error)
        XCTAssertTrue(on.output.hasPrefix("Stay awake is on until"), on.output)
        let onStatus = try object(await run("awake", "status", json: true))
        XCTAssertNotNil(onStatus["until"])
        let off = await run("awake", "off")
        XCTAssertEqual(off.output, "Stay awake is off.")
        let writes = await power.writes
        XCTAssertEqual(writes, [true, false])

        let wrong = await run("awake", "on", "--for", "2h")
        XCTAssertEqual(wrong.exitCode, AgentExit.usage)
        await power.deny()
        let denied = await run("awake", "on")
        XCTAssertEqual(denied.exitCode, AgentExit.failure)
        XCTAssertTrue(denied.error.contains("frog open stay-awake"), denied.error)
    }

    func testUsageListsEachProvider() async throws {
        try await enable(.usage)
        let providers = try array(await run("usage", json: true))
        XCTAssertEqual(providers.compactMap { $0["provider"] as? String }, ["Claude", "OpenAI"])
        let text = await run("usage")
        XCTAssertTrue(text.output.contains("Claude") && text.output.contains("OpenAI"), text.output)
    }

    func testMonitorTakesOneReading() async throws {
        let reading = try object(await run("monitor", json: true))
        XCTAssertGreaterThan(((reading["memory"] as? [String: Any])?["total"] as? Int) ?? 0, 0)
        XCTAssertNotNil(reading["power"])
    }

    func testCommandsOfAFeatureThatIsOffSayHowToTurnItOn() async throws {
        let cases: [([String], String)] = [
            (["scripts", "list"], "scripts"), (["snippets", "list"], "snippets"), (["notes", "list"], "notes"),
            (["shelf", "list"], "shelf"), (["clipboard", "list"], "clipboard"), (["usage"], "usage")
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
        for usage in ["scripts run <name> [--timeout SECONDS]", "snippets show <name> [--expand]", "notes append <name> [text]",
                      "shelf add <path or link>…", "clipboard list [--limit N]", "rules run <rule> <text>", "awake on", "monitor", "usage"] {
            XCTAssertTrue(help.output.contains(usage), usage)
        }
        let details = await run("help", "scripts", "run")
        XCTAssertTrue(details.output.contains("exit code"), details.output)
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
