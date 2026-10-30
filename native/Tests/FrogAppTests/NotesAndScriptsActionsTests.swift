import AppKit
import FrogAgent
import FrogCore
import XCTest
@testable import FrogApp

/// The Notes and Scripts plugins' actions, through the plugin host as `frog run`, the command bar and shortcuts
/// call them, against an isolated model with a pasteboard of its own.
@MainActor final class NotesAndScriptsActionsTests: XCTestCase {
    private var directory: URL!
    private var pasteboard: NSPasteboard!
    private var model: AppModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-documents-\(UUID().uuidString)")
        try ConfigurationStore(directory: directory).save(Configuration())
        pasteboard = NSPasteboard.withUniqueName()
        model = AppModel(dataDirectory: directory, registerShortcuts: false, readKey: { _ in nil }, writeClipboard: { _ in },
                         toolkit: Toolkit(showsUsageStatusItem: false),
                         clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard, gate: ClipboardHistoryCaptureGate()))
    }

    override func tearDown() async throws {
        model.shutdown()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    private func enable(_ features: FeatureID...) async throws {
        for feature in features { try await model.setFeature(feature, enabled: true) }
        await model.pluginHost.syncAndWait()
        // No test pastes into the field that has focus on this Mac.
        (model.pluginHost.running[NotesPlugin.info.id] as? NotesPlugin)?.captureTarget = { nil }
    }

    @discardableResult
    private func run(_ id: String, _ values: [String: String] = [:], text: String? = nil,
                     source: ActionInput.Source = .agent) async throws -> ActionResult {
        try await model.pluginHost.run(id, ActionInput(values: values, text: text, source: source))
    }

    private func failure(_ id: String, _ values: [String: String] = [:], text: String? = nil) async -> String {
        do {
            try await run(id, values, text: text)
            XCTFail("\(id) should fail")
            return ""
        } catch { return error.localizedDescription }
    }

    private func json(_ result: ActionResult) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(result.json.utf8))
    }

    private func store(_ items: UtilityDocument...) async {
        await model.documents.load()
        items.forEach { model.documents.add($0) }
        _ = await model.documents.flush()
    }

    // MARK: Notes

    func testNotesAreAddedListedReadAndAppendedTo() async throws {
        try await enable(.scratchpad)
        let added = try await run("notes.add", ["title": "Groceries"], text: "Milk")
        XCTAssertEqual(added.text, "Added the note “Groceries”.")
        let again = await failure("notes.add", ["title": "Groceries"])
        XCTAssertTrue(again.contains("already exists"), "A second note with the same title would make the name ambiguous: \(again)")
        try await run("notes.add", ["title": "Plan A"], text: "First")
        try await run("notes.add", ["title": "Plan B"])

        let list = try await run("notes.list")
        XCTAssertTrue(list.text.contains("Groceries") && list.text.contains("Plan B"), list.text)
        let entries = try XCTUnwrap(try json(list) as? [[String: Any]])
        XCTAssertEqual(entries.compactMap { $0["title"] as? String }.sorted(), ["Groceries", "Plan A", "Plan B"])

        let read = try await run("notes.read", ["title": "groc"])
        XCTAssertEqual(read.text, "Milk", "A unique start of the title in any case is enough")
        try await run("notes.append", ["title": "Groceries"], text: "Bread and butter")
        let reread = try await run("notes.read", ["title": "Groceries"])
        let appended = try XCTUnwrap(try json(reread) as? [String: Any])
        XCTAssertEqual(appended["text"] as? String, "Milk\nBread and butter")
        let empty = await failure("notes.append", ["title": "Groceries"])
        XCTAssertTrue(empty.contains("standard input"), empty)

        let ambiguous = await failure("notes.read", ["title": "plan"])
        XCTAssertTrue(ambiguous.contains("Plan A") && ambiguous.contains("Plan B"), ambiguous)
        let missing = await failure("notes.read", ["title": "Holiday"])
        XCTAssertTrue(missing.contains("frog run notes.list"), missing)
        let untitled = await failure("notes.read")
        XCTAssertEqual(untitled, "Missing --title.")

        let saved = try await UtilityDocumentStore(directory: directory.appendingPathComponent("Toolkit")).load()
        XCTAssertEqual(saved.first { $0.title == "Groceries" }?.text, "Milk\nBread and butter", "Each change is on disk when the action answers")
        XCTAssertEqual(saved.filter { $0.kind == .note }.count, 3)
    }

    func testAnAgentRunsThemWithFrogRun() async throws {
        try await enable(.scratchpad)
        let added = await AgentCommands.run(AgentRequest(arguments: ["run", "notes.add", "--title", "Piped"], directory: directory.path,
                                                         input: "From standard input"), model: model)
        XCTAssertEqual(added.exitCode, 0, added.error)
        let read = await AgentCommands.run(AgentRequest(arguments: ["run", "notes.read", "--title", "Piped"], directory: directory.path), model: model)
        XCTAssertEqual(read.output, "From standard input")
        let retired = await AgentCommands.run(AgentRequest(arguments: ["notes", "list"], directory: directory.path), model: model)
        XCTAssertEqual(retired.exitCode, AgentExit.usage)
        XCTAssertTrue(retired.error.contains("frog actions notes"), retired.error)
    }

    func testAChangeThatCannotBeSavedIsTakenBackSoARetryAddsItOnce() async throws {
        try await enable(.scratchpad)
        await store()
        try await run("notes.add", ["title": "Groceries"], text: "Milk")
        // A file where the documents' folder belongs makes every save fail.
        let folder = directory.appendingPathComponent("Toolkit")
        try FileManager.default.removeItem(at: folder)
        try Data().write(to: folder)

        _ = await failure("notes.add", ["title": "Call Anna"])
        _ = await failure("notes.append", ["title": "Groceries"], text: "Bread")
        XCTAssertEqual(model.documents.items.map(\.title), ["Groceries"])
        XCTAssertEqual(model.documents.items.first?.text, "Milk")

        try FileManager.default.removeItem(at: folder)
        try await run("notes.add", ["title": "Call Anna"])
        try await run("notes.append", ["title": "Groceries"], text: "Bread")
        let saved = try await UtilityDocumentStore(directory: folder).load()
        XCTAssertEqual(saved.map(\.title).sorted(), ["Call Anna", "Groceries"])
        XCTAssertEqual(saved.first { $0.title == "Groceries" }?.text, "Milk\nBread")
    }

    func testAddingANoteSaysWhenTheStoreIsFull() async throws {
        try await enable(.scratchpad)
        await model.documents.load()
        for index in 0..<999 { model.documents.add(UtilityDocument(kind: .script, title: "Script \(index)", text: "")) }
        try await run("notes.add", ["title": "Last"])
        let full = await failure("notes.add", ["title": "One too many"])
        XCTAssertTrue(full.contains("up to 1000"), full)
        XCTAssertEqual(model.documents.items.count, 1000)
    }

    func testNotesThatPasteExpandWithoutRevealingSensitiveText() async throws {
        try await enable(.scratchpad)
        await store(UtilityDocument(kind: .note, title: "Greeting", text: "Hi {{clipboard}}, {{date}}", pastes: true))
        pasteboard.clearContents(); pasteboard.setString("Anna", forType: .string)

        let raw = try await run("notes.read", ["title": "Greeting"])
        XCTAssertEqual(raw.text, "Hi {{clipboard}}, {{date}}")
        let expanded = try await run("notes.read", ["title": "greeting", "expand": "true"])
        XCTAssertTrue(expanded.text.hasPrefix("Hi Anna, ") && !expanded.text.contains("{{"), expanded.text)
        let list = try await run("notes.list")
        XCTAssertTrue(list.text.contains("pastes"), list.text)
        XCTAssertEqual((try json(list) as? [[String: Any]])?.first?["pastes"] as? Bool, true)

        XCTAssertTrue(ClipboardHistoryEntry(text: "hunter2", isSensitive: true).write(to: pasteboard, plainText: true))
        let concealed = await failure("notes.read", ["title": "Greeting", "expand": "true"])
        XCTAssertFalse(concealed.contains("hunter2"), concealed)

        // A one-time code an app marks as transient is hidden the same way.
        let transient = NSPasteboardItem()
        transient.setString("482913", forType: .string)
        transient.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents(); pasteboard.writeObjects([transient])
        let code = await failure("notes.read", ["title": "Greeting", "expand": "true"])
        XCTAssertFalse(code.contains("482913"), code)
    }

    func testPastingWithoutAFieldCopiesTheFilledInNote() async throws {
        try await enable(.scratchpad)
        await store(UtilityDocument(kind: .note, title: "Sign-off", text: "Thanks, {{clipboard}}", pastes: true),
                    UtilityDocument(kind: .note, title: "Plain", text: "Kept as {{written}}"))
        pasteboard.clearContents(); pasteboard.setString("Jo", forType: .string)

        let pasted = try await run("notes.paste", ["title": "Sign-off"], source: .shortcut)
        XCTAssertTrue(pasted.text.contains("no text field has focus"), pasted.text)
        XCTAssertEqual(pasteboard.string(forType: .string), "Thanks, Jo")
        try await run("notes.copy", ["title": "Plain"])
        XCTAssertEqual(pasteboard.string(forType: .string), "Kept as {{written}}", "A note that does not paste is copied as written")
    }

    func testNotesOffHidesTheirActions() async throws {
        await model.pluginHost.syncAndWait()
        XCTAssertNil(model.pluginHost.action("notes.list"))
        let off = await failure("notes.list")
        XCTAssertTrue(off.contains("Notes is off"), off)
    }

    // MARK: Scripts

    func testScriptsRunForAnAgentAndSayHowTheyEnded() async throws {
        try await enable(.scripts)
        await store(UtilityDocument(kind: .script, title: "Hello", text: "echo hello"),
                    UtilityDocument(kind: .script, title: "Fails", text: "echo partial; exit 3"),
                    UtilityDocument(kind: .script, title: "Slow", text: "echo started; sleep 5"))

        let list = try await run("scripts.list")
        XCTAssertTrue(list.text.contains("echo partial; exit 3"), list.text)
        let script = try await run("scripts.read", ["title": "hello"])
        XCTAssertEqual(script.text, "echo hello")

        let hello = try await run("scripts.run", ["title": "Hello"])
        XCTAssertEqual(hello.text, "hello\n")
        let run = try XCTUnwrap(try json(hello) as? [String: Any])
        XCTAssertEqual(run["status"] as? Int, 0)
        XCTAssertEqual(run["truncated"] as? Bool, false)

        let fails = try await self.run("scripts.run", ["title": "Fails"])
        XCTAssertEqual(fails.text, "partial\n")
        XCTAssertEqual(fails.exitCode, 3, "frog run exits with the script's own status")
        XCTAssertTrue(fails.notice.contains("status 3"), fails.notice)
        let agent = await AgentCommands.run(AgentRequest(arguments: ["run", "scripts.run", "--title", "Fails"], directory: directory.path), model: model)
        XCTAssertEqual(agent.exitCode, 3)
        XCTAssertEqual(agent.output, "partial\n")
        let prefix = await failure("scripts.run", ["title": "Hel"])
        XCTAssertTrue(prefix.contains("exactly"), "Running takes the exact title: \(prefix)")
        let slow = await failure("scripts.run", ["title": "Slow", "timeout": "1"])
        XCTAssertTrue(slow.contains("started"), "What it printed before the time ran out: \(slow)")
        let wrong = await failure("scripts.run", ["title": "Hello", "timeout": "0"])
        XCTAssertTrue(wrong.contains("--timeout"), wrong)
    }

    func testTheTimeLimitComesFromConfig() async throws {
        try await enable(.scripts)
        await store(UtilityDocument(kind: .script, title: "Slow", text: "sleep 5"))
        let plugin = try XCTUnwrap(model.pluginHost.running[ScriptsPlugin.info.id] as? ScriptsPlugin)
        XCTAssertEqual(plugin.settings.timeout, 60)
        var settings = plugin.settings
        settings.timeout = 1
        try model.settingsFile.update(ScriptsPlugin.info.id, settings)
        plugin.settingsChanged()
        let started = ContinuousClock.now
        _ = await failure("scripts.run", ["title": "Slow"])
        XCTAssertLessThan(started.duration(to: .now), .seconds(4), "[scripts] timeout = 1 stops it after a second")
    }

    func testQuittingStopsAScriptAnAgentStarted() async throws {
        try await enable(.scripts)
        await store(UtilityDocument(kind: .script, title: "Long", text: "sleep 30"))
        let running = Task { try? await self.run("scripts.run", ["title": "Long", "timeout": "60"]) }
        for _ in 0..<200 where !model.scripts.needsQuitCleanup { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.scripts.needsQuitCleanup, "Quitting waits for the agent's script")
        let started = ContinuousClock.now
        await model.scripts.stopAndWait()
        let result = await running.value
        XCTAssertLessThan(started.duration(to: .now), .seconds(10))
        XCTAssertNil(result, "A stopped script fails")
        XCTAssertFalse(model.scripts.needsQuitCleanup)
    }

    func testStoppingScriptsStopsTheRunsAnAgentStarted() async throws {
        try await enable(.scripts)
        await store(UtilityDocument(kind: .script, title: "Long", text: "sleep 30"))
        for stop in ["action", "plugin"] {
            let running = Task { try? await self.run("scripts.run", ["title": "Long", "timeout": "60"]) }
            for _ in 0..<200 where model.scripts.runCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
            let started = ContinuousClock.now
            if stop == "action" {
                let stopped = try await run("scripts.stop")
                XCTAssertEqual(stopped.text, "Stopped the script.")
            } else {
                await (model.pluginHost.running[ScriptsPlugin.info.id] as? ScriptsPlugin)?.stop()
            }
            let result = await running.value
            XCTAssertNil(result, "Stopped by the \(stop)")
            XCTAssertLessThan(started.duration(to: .now), .seconds(10))
            XCTAssertEqual(model.scripts.runCount, 0)
        }
    }
}
