import AppKit
import XCTest
import FrogCore
@testable import FrogApp

/// What Learn from your choices keeps and how the bar ranks with it, decided without presenting the bar's panel.
@MainActor final class CommandChoiceRankingTests: XCTestCase {
    private let calendar = "fixture:calendar", calculator = "fixture:calculator"

    func testRowsPickedForTypedTextLeadAfterARelaunch() async throws {
        let root = try directory(learning: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Harness(root)
        XCTAssertEqual(first.fixtureOrder("ca"), [calculator, calendar])
        try await first.pick(calendar, after: "ca")
        try await first.pick(calendar, after: "Ca ")
        first.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: choicesFile(root).path))

        let relaunched = Harness(root)
        defer { relaunched.close() }
        XCTAssertEqual(relaunched.model.commandChoices.count, 1)
        relaunched.bar.prepareResults(relaunched.model, frontPID: nil)
        // The opening list starts with the strongest rows.
        XCTAssertEqual(relaunched.bar.results.first?.id, calendar)
        XCTAssertEqual(relaunched.fixtureOrder("ca"), [calendar, calculator])
        XCTAssertEqual(relaunched.bar.results.first?.id, calendar)
        // A learned row is never listed for text that does not find it.
        XCTAssertFalse(relaunched.ids("cx").contains(calendar))
    }

    func testWithLearningOffNothingIsWrittenAndPicksOnlyBreakTiesUntilQuit() async throws {
        let root = try directory(learning: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Harness(root)
        try await first.pick(calendar, after: "ca")
        try await first.pick(calendar, after: "ca")
        XCTAssertEqual(first.fixtureOrder("ca"), [calendar, calculator])
        first.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: choicesFile(root).path))
        let relaunched = Harness(root)
        defer { relaunched.close() }
        XCTAssertEqual(relaunched.fixtureOrder("ca"), [calculator, calendar])
    }

    func testAClipboardRowThatIsPickedLeavesNoTrace() async throws {
        let root = try directory(learning: true, features: [.clipboard])
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = Harness(root)
        defer { harness.close() }
        harness.model.clipboardHistoryStore.configure(enabled: true, automaticallyPoll: false)
        harness.model.clipboardHistoryStore.recordCopiedText("fixture secret 4417")
        let clip = try XCTUnwrap(harness.ids("4417").first { $0.hasPrefix("clipboard:") })
        try await harness.pick(clip, after: "4417", copy: true)
        try await harness.pick(calendar, after: "ca")
        harness.model.commandChoices.waitForWrites()
        let saved = try String(contentsOf: choicesFile(root), encoding: .utf8)
        XCTAssertTrue(saved.contains(calendar))
        XCTAssertFalse(saved.contains("clipboard:"))
        XCTAssertFalse(saved.contains("4417"))
        XCTAssertEqual(harness.model.commandChoices.count, 1)
    }

    func testAPickThatFailsOrIsCancelledIsNotLearned() async throws {
        let root = try directory(learning: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = Harness(root)
        defer { harness.close() }
        harness.rows.failing = [calendar]
        harness.bar.prepareResults(harness.model, frontPID: nil)
        harness.bar.query = "ca"
        harness.bar.choose(try XCTUnwrap(harness.bar.results.firstIndex { $0.id == calendar }))
        for _ in 0..<200 where harness.model.errorMessage == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(harness.model.errorMessage, "Fixture failure")

        // Reopening the bar cancels a delivery still under way.
        harness.rows.failing = []
        let gate = harness.rows.holdNextRun()
        harness.bar.prepareResults(harness.model, frontPID: nil)
        harness.bar.query = "ca"
        harness.bar.choose(try XCTUnwrap(harness.bar.results.firstIndex { $0.id == calendar }))
        for _ in 0..<200 where !gate.started { try await Task.sleep(for: .milliseconds(5)) }
        harness.bar.hide(); harness.bar.prepareResults(harness.model, frontPID: nil)
        gate.release()
        for _ in 0..<200 where harness.rows.runs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(20))
        harness.model.commandChoices.waitForWrites()
        XCTAssertEqual(harness.model.commandChoices.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: choicesFile(root).path))
    }

    func testTurningLearningOrTheCommandBarOffForgetsAndALatePickIsNotKept() async throws {
        let root = try directory(learning: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = Harness(root)
        defer { harness.close() }
        let file = choicesFile(root)
        func learning(_ on: Bool, commandBar: Bool = true) throws {
            var preferences = harness.model.configuration.preferences
            preferences.setFeature(.commandBar, enabled: commandBar)
            preferences.toolkit?.commandBar = CommandBarPreferences(); preferences.toolkit?.commandBar?.learnChoices = on
            try harness.model.savePreferences(preferences)
            harness.model.commandChoices.waitForWrites()
        }
        try await harness.pick(calendar, after: "ca")
        harness.model.commandChoices.waitForWrites()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try learning(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(harness.model.commandChoices.count, 0)

        try learning(true)
        try await harness.pick(calendar, after: "ca")
        harness.model.commandChoices.waitForWrites()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try learning(true, commandBar: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // A pick whose action finishes after the switch went off is not kept.
        try learning(true)
        harness.rows.runs = []
        let gate = harness.rows.holdNextRun()
        harness.bar.prepareResults(harness.model, frontPID: nil)
        harness.bar.query = "ca"
        harness.bar.choose(try XCTUnwrap(harness.bar.results.firstIndex { $0.id == calendar }))
        for _ in 0..<200 where !gate.started { try await Task.sleep(for: .milliseconds(5)) }
        try learning(false)
        gate.release()
        for _ in 0..<200 where harness.rows.runs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(20))
        harness.model.commandChoices.waitForWrites()
        XCTAssertEqual(harness.rows.runs, [calendar])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLearnedFilesAreListedBeforeTheFileSearchAnswers() async throws {
        let root = try directory(learning: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("Fixture Budget.txt")
        try Data("fixture".utf8).write(to: document)
        let id = "file:\(document.path)"
        let harness = Harness(root)
        harness.bar.prepareResults(harness.model, frontPID: nil)
        harness.bar.query = "budget"
        XCTAssertFalse(harness.bar.results.contains { $0.id == id })
        harness.bar.listFiles([SearchRecord(id: id, title: document.lastPathComponent, symbol: "doc")], recent: false)
        try await harness.pick(id, after: "budget", prepared: true)
        harness.close()

        // After a relaunch the file search of the first open has not answered yet.
        let relaunched = Harness(root)
        for _ in 0..<200 where relaunched.model.commandChoices.learnedFiles.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(relaunched.model.commandChoices.learnedFiles.map(\.id), [id])
        XCTAssertEqual(relaunched.model.commandChoices.learnedFiles.first?.title, "Fixture Budget.txt")
        XCTAssertEqual(relaunched.ids("budget").first, id)
        XCTAssertFalse(relaunched.ids("zzz").contains(id))
        relaunched.close()

        try FileManager.default.removeItem(at: document)
        let later = Harness(root)
        defer { later.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(later.model.commandChoices.learnedFiles.isEmpty)
        XCTAssertFalse(later.ids("budget").contains(id))
    }

    func testPicksAreSavedOffTheMainThread() async throws {
        let root = try directory(learning: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = Harness(root)
        defer { harness.close() }
        let queue = harness.model.commandChoices.queue
        // Nothing can be saved while the queue is held, so a file that exists was written on the calling thread.
        queue.suspend()
        try await harness.pick(calendar, after: "ca")
        let saved = FileManager.default.fileExists(atPath: choicesFile(root).path)
        let counted = harness.model.commandChoices.count
        queue.resume()
        XCTAssertFalse(saved, "A pick must not wait for the disk")
        XCTAssertEqual(counted, 1)
        XCTAssertEqual(harness.fixtureOrder("ca"), [calendar, calculator])
        harness.model.commandChoices.waitForWrites()
        XCTAssertEqual(try CommandChoicesPersistence(directory: root).load().pairs.map(\.id), [calendar])
    }

    func testAnUnreadableFilePausesLearningUntilItIsForgotten() async throws {
        let root = try directory(learning: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = Data("{ not choices".utf8)
        try broken.write(to: choicesFile(root))
        let harness = Harness(root)
        defer { harness.close() }
        let store = harness.model.commandChoices
        XCTAssertNotNil(store.issue)
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(harness.fixtureOrder("ca"), [calculator, calendar])
        try await harness.pick(calendar, after: "ca")
        store.waitForWrites()
        XCTAssertEqual(try Data(contentsOf: choicesFile(root)), broken)

        harness.model.forgetCommandChoices()
        store.waitForWrites()
        XCTAssertNil(store.issue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: choicesFile(root).path))
        try await harness.pick(calculator, after: "ca")
        store.waitForWrites()
        XCTAssertEqual(try CommandChoicesPersistence(directory: root).load().pairs.map(\.id), [calculator])
    }

    private func choicesFile(_ root: URL) -> URL { root.appendingPathComponent("command-choices.json") }

    private func directory(learning: Bool, features: [FeatureID] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var config = Configuration(); config.preferences.windowSwitcherEnabled = false
        for feature in [.commandBar] + features { config.preferences.setFeature(feature, enabled: true) }
        config.preferences.toolkit?.commandBar = CommandBarPreferences()
        config.preferences.toolkit?.commandBar?.learnChoices = learning
        try ConfigurationStore(directory: root).save(config)
        return root
    }
}

/// One launch of Frog: a model on the directory and a bar whose only rows of interest are two fixtures.
@MainActor private final class Harness {
    let model: AppModel
    let bar: CommandBar
    let rows = FixtureRows()
    private let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
    private var picks = 0

    init(_ root: URL) {
        model = AppModel(dataDirectory: root, registerShortcuts: false, readKey: { _ in nil },
                         clipboardHistoryStore: ClipboardHistoryStore(pasteboard: pasteboard))
        bar = CommandBar(model: model, pasteboard: pasteboard, captureTarget: { nil }, waitForRelease: {},
                         fileSearch: SilentFileSearch(), openFile: { _ in true }, loadSettings: { [] },
                         loadApplications: { [] }, extraProviders: [rows])
        bar.onToolUse = { [weak self] in if $0 == .commandSelection { self?.picks += 1 } }
    }

    func close() { bar.stop(); model.shutdown(); pasteboard.releaseGlobally() }

    func ids(_ query: String) -> [String] {
        bar.prepareResults(model, frontPID: nil)
        bar.query = query
        return bar.results.map(\.id)
    }
    func fixtureOrder(_ query: String) -> [String] { ids(query).filter { $0.hasPrefix("fixture:") } }

    func pick(_ id: String, after typed: String, copy: Bool = false, prepared: Bool = false) async throws {
        if !prepared { bar.prepareResults(model, frontPID: nil); bar.query = typed }
        let before = picks
        bar.choose(try XCTUnwrap(bar.results.firstIndex { $0.id == id }, "\(id) for \(typed)"), copyOnly: copy)
        for _ in 0..<200 where picks == before { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(picks, before + 1, "\(id) for \(typed)")
    }
}

/// Two rows found by "ca", listed as applications are, whose actions only note that they ran.
@MainActor private final class FixtureRows: CommandBarRowProviding {
    var runs: [String] = []
    var failing: Set<String> = []
    private var gate: Gate?

    @MainActor final class Gate {
        private(set) var started = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            started = true
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    func holdNextRun() -> Gate { let gate = Gate(); self.gate = gate; return gate }

    func rows(in context: CommandBarContext) -> [CommandBarRow] {
        ["Calculator", "Calendar"].map { title in
            let id = "fixture:\(title.lowercased())"
            return CommandBarRow(record: SearchRecord(id: id, title: title, subtitle: "App", symbol: "app", prominent: true),
                                 primary: CommandRowAction(title: "Open") { [weak self] in
                guard let self else { return }
                if let gate = self.gate { self.gate = nil; await gate.wait() }
                if self.failing.contains(id) { throw FrogError.message("Fixture failure") }
                self.runs.append(id)
            })
        }
    }
}

@MainActor private final class SilentFileSearch: CommandFileSearching {
    func start(text: String, scopes: [Any], receive: @escaping @MainActor ([SearchRecord]) -> Void) {}
    func stop() {}
}
