import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class ExplainRoutingTests: XCTestCase {
    private static let anchor = CGRect(x: 120, y: 480, width: 42, height: 16)

    func testAnAnswerRuleDoesNothingWhileExplainIsOff() async throws {
        let setup = try Setup(test: self)
        var answer = Rule.explainPreset
        answer.providerID = setup.model.configuration.providers[0].id
        try setup.model.saveRule(answer)
        setup.model.processSelection(ruleID: answer.id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(setup.streams.requests.isEmpty)
        XCTAssertEqual(setup.completions, 0)
        XCTAssertTrue(setup.presenter.shown.isEmpty)
        XCTAssertEqual(setup.captures, 0)
    }

    func testTurningExplainOnAddsTheExplainRuleOnce() async throws {
        let setup = try Setup(test: self)
        XCTAssertFalse(setup.model.configuration.rules.contains { $0.answersInPanel })
        try await setup.model.setFeature(.explain, enabled: true)
        XCTAssertEqual(setup.model.configuration.rules.filter { $0.answersInPanel && $0.name == "Explain" }.count, 1)
        XCTAssertTrue(setup.model.configuration.preferences.sidebarFeatures.contains(.explain))
        try await setup.model.setFeature(.explain, enabled: false)
        try await setup.model.setFeature(.explain, enabled: true)
        XCTAssertEqual(setup.model.configuration.rules.filter(\.answersInPanel).count, 1)
    }

    func testRunningAnAnswerRuleStreamsTheSelectionWithoutItsSource() async throws {
        let setup = try Setup(test: self)
        let rule = try await setup.enableExplain()
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.presenter.sessions.last?.phase == .done(truncated: false) }
        XCTAssertEqual(setup.streams.requests.count, 1)
        let first = try XCTUnwrap(setup.streams.requests.first?.messages.first?.text)
        XCTAssertTrue(first.contains(setup.selection.text), first)
        XCTAssertTrue(first.contains("Surrounding text"), first)
        XCTAssertTrue(first.contains(try XCTUnwrap(setup.selection.context)), first)
        XCTAssertTrue(first.contains("App: Notes"), first)
        XCTAssertFalse(setup.streams.requests.contains { request in
            request.messages.contains { $0.text.contains("example.com") } || request.instructions.contains("example.com")
        })
        XCTAssertEqual(setup.presenter.anchors, [Self.anchor])
        XCTAssertEqual(setup.completions, 0)
        XCTAssertNil(setup.selection.replacement, "An answer never replaces the selection")
    }

    func testWithoutSurroundingTextTheContextIsNotSent() async throws {
        let setup = try Setup(test: self)
        let rule = try await setup.enableExplain()
        try setup.model.updateToolkit { toolkit in
            var settings = toolkit.explain ?? ExplainSettings()
            settings.includeContext = false
            toolkit.explain = settings
        }
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.streams.requests.count == 1 }
        let first = try XCTUnwrap(setup.streams.requests.first?.messages.first?.text)
        XCTAssertTrue(first.contains(setup.selection.text))
        XCTAssertFalse(first.contains("Surrounding text"), first)
    }

    func testAWritingRuleStillCompletesAndReplaces() async throws {
        let setup = try Setup(test: self)
        _ = try await setup.enableExplain()
        let writing = try XCTUnwrap(setup.model.configuration.rules.first { $0.category == .text && !$0.answersInPanel })
        setup.model.processSelection(ruleID: writing.id)
        try await waitUntil { !setup.model.isProcessing && setup.completions == 1 }
        XCTAssertEqual(setup.selection.replacement, "Replaced")
        XCTAssertTrue(setup.streams.requests.isEmpty)
        XCTAssertTrue(setup.presenter.shown.isEmpty)
    }

    func testDisablingExplainClosesThePanelAndCancelsTheStream() async throws {
        let setup = try Setup(test: self)
        let rule = try await setup.enableExplain()
        setup.streams.hangs = true
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.streams.requests.count == 1 }
        try await setup.model.setFeature(.explain, enabled: false)
        XCTAssertGreaterThanOrEqual(setup.presenter.closed, 1)
        try await waitUntil { setup.streams.termination.count == 1 }
        XCTAssertNil(setup.model.answers.session)
    }

    func testAFrogModelIsLabelledWithItsNameAndFrog() async throws {
        let setup = try Setup(test: self, installedTextModel: true)
        let id = try XCTUnwrap(setup.installedModelID)
        var rule = try await setup.enableExplain()
        rule.providerID = nil
        rule.action?.localTextModelID = id
        try setup.model.saveRule(rule)
        XCTAssertEqual(setup.model.configuration.rules.first { $0.id == rule.id }?.action?.localTextModelID, id)
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.streams.requests.count == 1 }
        let name = try XCTUnwrap(setup.model.configuration.localModel(id)?.name)
        XCTAssertEqual(setup.presenter.shown.first?.modelLabel, "\(name) · Frog")
        XCTAssertEqual(setup.streams.requests.first?.isFrogLocal, true)
    }

    func testAnAnswerRuleFollowsExplainForItsShortcut() {
        var configuration = Configuration()
        var answer = Rule.explainPreset
        answer.hotkey = Hotkey(keyCode: 14, modifiers: 256 | 2048)
        configuration.rules = [answer]
        XCTAssertFalse(configuration.preferences.ruleFeatureEnabled(answer))
        XCTAssertFalse(AppModel.hotkeyRules(for: configuration).contains { $0.id == answer.id })
        configuration.preferences.setFeature(.explain, enabled: true)
        XCTAssertTrue(configuration.preferences.ruleFeatureEnabled(answer))
        XCTAssertTrue(AppModel.hotkeyRules(for: configuration).contains { $0.id == answer.id })
        configuration.preferences.setFeature(.writing, enabled: false)
        XCTAssertTrue(configuration.preferences.ruleFeatureEnabled(answer), "Writing does not decide over answer rules")
        configuration.preferences.setFeature(.explain, enabled: false)
        configuration.preferences.setFeature(.writing, enabled: true)
        XCTAssertFalse(configuration.preferences.ruleFeatureEnabled(answer))
    }

    // MARK: History

    func testWithHistoryOnAnAnswerIsSavedOnceAndItsFollowUpsUpdateTheSameEntry() async throws {
        let setup = try Setup(test: self)
        let rule = try await setup.enableExplain()
        try setup.setHistory(true)
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.model.history.count == 1 }
        let entry = setup.model.history[0]
        XCTAssertEqual(entry.ruleName, rule.name)
        XCTAssertEqual(entry.originalText, setup.selection.text)
        XCTAssertEqual(entry.processedText, "A raised strip of land along a river.")
        XCTAssertEqual(entry.providerName, setup.model.configuration.providers[0].name)
        XCTAssertEqual(entry.answer, AnswerRecord(context: setup.selection.context, application: "Notes",
                                                  source: setup.selection.source, followUps: []))
        XCTAssertEqual(setup.model.answers.session?.historyEntryID, entry.id)

        XCTAssertNil(setup.model.answers.ask("And on a boat?"))
        try await waitUntil { setup.model.history.first?.answer?.followUps.count == 1 }
        XCTAssertEqual(setup.model.history.map(\.id), [entry.id])
        XCTAssertEqual(setup.model.history[0].answer?.followUps.first?.question, "And on a boat?")
        setup.model.refreshHistory()
        XCTAssertEqual(setup.model.history.count, 1, "The file holds one entry")
        XCTAssertEqual(setup.model.history[0].answer?.followUps.count, 1)
    }

    func testWithHistoryOffOrTurnedOffDuringTheAnswerNothingIsSaved() async throws {
        let setup = try Setup(test: self)
        let rule = try await setup.enableExplain()
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.presenter.sessions.last?.phase == .done(truncated: false) }
        try setup.setHistory(true)
        setup.model.refreshHistory()
        XCTAssertTrue(setup.model.history.isEmpty, "History was off when the answer started")

        setup.streams.hangs = true
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.streams.requests.count == 2 }
        try setup.setHistory(false)
        try setup.setHistory(true)
        setup.streams.release()
        try await waitUntil { setup.model.answers.session?.phase == .done(truncated: false) }
        setup.model.refreshHistory()
        XCTAssertTrue(setup.model.history.isEmpty, "Turning History off during the answer stops it being saved")
    }

    func testAFollowUpAfterHistoryWasClearedDoesNotRecreateTheEntry() async throws {
        let setup = try Setup(test: self)
        let rule = try await setup.enableExplain()
        try setup.setHistory(true)
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.model.history.count == 1 }
        try setup.model.clearHistory()
        XCTAssertNil(setup.model.answers.ask("And on a boat?"))
        try await waitUntil { setup.model.answers.session?.turns.count == 2 }
        setup.model.refreshHistory()
        XCTAssertTrue(setup.model.history.isEmpty)

        // An answer still running when History is cleared is not saved either.
        setup.streams.hangs = true
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.streams.requests.count == 3 }
        try setup.model.clearHistory()
        setup.streams.release()
        try await waitUntil { setup.model.answers.session?.phase == .done(truncated: false) }
        setup.model.refreshHistory()
        XCTAssertTrue(setup.model.history.isEmpty)
    }

    func testAFailedOrStoppedAnswerSavesNothing() async throws {
        let setup = try Setup(test: self)
        let rule = try await setup.enableExplain()
        try setup.setHistory(true)
        setup.streams.failure = FrogError.message("The server is offline.")
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.model.answers.session?.phase == .failed("The server is offline.") }

        setup.streams.failure = nil
        setup.streams.hangs = true
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.streams.requests.count == 2 }
        setup.model.answers.stop()
        XCTAssertEqual(setup.model.answers.session?.phase, .stopped)
        setup.model.refreshHistory()
        XCTAssertTrue(setup.model.history.isEmpty)
    }

    // MARK: Notes

    func testSavingANoteNeedsNotesOnAndAsksForTheFolderOnceWithHistoryOff() async throws {
        let setup = try Setup(test: self)
        _ = try await setup.enableExplain()
        let content = AnswerNoteContent(ruleName: "Explain", selection: "river bank", modelLabel: "Qwen3 4B · Frog", application: "Notes",
                                        source: nil, date: Date(), turns: [AnswerTurn(question: "", answer: "A raised strip.")])
        do {
            _ = try await setup.model.saveAnswerNote(content)
            XCTFail("Saved with notes off")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Turn on Save answers to notes on the Explain page.")
        }
        XCTAssertEqual(setup.folderChoices, 0)

        try setup.turnOnNotes()
        XCTAssertFalse(setup.model.configuration.preferences.historyEnabled)
        let first = try await setup.model.saveAnswerNote(content)
        XCTAssertEqual(setup.folderChoices, 1)
        XCTAssertEqual(setup.model.configuration.preferences.explainSettings.notesFolderURL?.resolvingSymlinksInPath().path,
                       setup.notesFolder.resolvingSymlinksInPath().path)
        XCTAssertEqual(first.lastPathComponent, "river bank.md")
        let second = try await setup.model.saveAnswerNote(content)
        XCTAssertEqual(second.lastPathComponent, "river bank 2.md")
        XCTAssertEqual(setup.folderChoices, 1, "The stored folder is used from then on")
        XCTAssertTrue(setup.model.history.isEmpty)
    }

    func testTheAnswerPanelSavesItsConversationAndShowsTheOutcome() async throws {
        let setup = try Setup(test: self)
        let rule = try await setup.enableExplain()
        XCTAssertFalse(setup.model.answers.offersNotes)
        try setup.turnOnNotes()
        XCTAssertTrue(setup.model.answers.offersNotes)
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.model.answers.session?.phase == .done(truncated: false) }
        XCTAssertTrue(setup.model.answers.canSaveNote)
        setup.model.answers.saveToNote()
        try await waitUntil { setup.model.answers.noteState == .saved }
        let note = try String(contentsOf: setup.notesFolder.appendingPathComponent("river bank.md"), encoding: .utf8)
        XCTAssertTrue(note.contains("A raised strip of land along a river."), note)
        XCTAssertFalse(note.contains("light went"), "The surrounding text is never written")
        XCTAssertTrue(note.contains("\nsource: \"https://example.com/private/page\"\n"), "The source is kept on this Mac")

        // A folder that is gone shows the reason in the panel and in Logs.
        try FileManager.default.removeItem(at: setup.notesFolder)
        setup.model.answers.saveToNote()
        try await waitUntil { setup.model.answers.noteState == .failed("Choose a notes folder that exists.") }
        XCTAssertTrue(setup.model.recentErrors.contains { $0.message.contains("Choose a notes folder that exists.") })
    }

    func testCancellingTheFolderChoiceSavesNothingAndShowsNoError() async throws {
        let setup = try Setup(test: self)
        _ = try await setup.enableExplain()
        try setup.turnOnNotes()
        setup.cancelsFolderChoice = true
        let content = AnswerNoteContent(ruleName: "Explain", selection: "x", modelLabel: "", application: nil, source: nil,
                                        date: Date(), turns: [AnswerTurn(question: "", answer: "y")])
        do {
            _ = try await setup.model.saveAnswerNote(content)
            XCTFail("Saved without a folder")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(setup.model.configuration.preferences.explainSettings.notesFolder)
        XCTAssertTrue(setup.model.recentErrors.isEmpty)
    }

    // MARK: Reading the selection

    func testASelectionReadThroughAccessibilityIsAnsweredWithoutCopying() async throws {
        let snapshot = SelectionSnapshot(text: "levee", bounds: Self.anchor, endBounds: nil, context: "The levee held all night.",
                                         source: "https://example.com/flood", isEditable: false, pid: FakeSelectionReader.pid,
                                         bundleID: "com.apple.Safari", applicationName: "Safari",
                                         fingerprint: SelectionFingerprint(pid: FakeSelectionReader.pid, element: 1, location: 0,
                                                                           length: 5, textHash: 0))
        let reader = FakeSelectionReader(.selection(snapshot))
        let setup = try Setup(test: self, reader: reader)
        let rule = try await setup.enableExplain()
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.presenter.sessions.last?.phase == .done(truncated: false) }
        XCTAssertEqual(setup.captures, 0, "No compatibility Copy")
        XCTAssertEqual(reader.calls.map(\.pid), [FakeSelectionReader.pid])
        XCTAssertEqual(reader.calls.first?.maxCharacters, 100_000)
        XCTAssertEqual(reader.calls.first?.includeContext, true)
        let first = try XCTUnwrap(setup.streams.requests.first?.messages.first?.text)
        XCTAssertTrue(first.contains("levee"), first)
        XCTAssertTrue(first.contains("The levee held all night."), first)
        XCTAssertTrue(first.contains("App: Safari"), first)
        XCTAssertEqual(setup.presenter.anchors, [Self.anchor])
        XCTAssertEqual(setup.model.answers.session?.source, "https://example.com/flood")
    }

    func testOnlyAnAppThatDoesNotExposeTheSelectionGetsTheCompatibilityCopy() async throws {
        let reader = FakeSelectionReader(.empty)
        let setup = try Setup(test: self, reader: reader)
        let rule = try await setup.enableExplain()
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.model.answers.session?.phase == .failed("Select some text first.") }

        reader.result = .secure
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.model.answers.session?.phase == .failed("Frog does not read password fields.") }

        reader.result = .tooLong(150_000)
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.model.answers.session?.phase == .failed(AnswerPrompt.selectionTooLong(limit: 100_000)) }
        XCTAssertEqual(setup.captures, 0)
        XCTAssertTrue(setup.streams.requests.isEmpty)

        reader.result = .unavailable
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.streams.requests.count == 1 }
        XCTAssertEqual(setup.captures, 1, "Falls back to the compatibility Copy")
        XCTAssertTrue(try XCTUnwrap(setup.streams.requests.first?.messages.first?.text).contains(setup.selection.text))
        XCTAssertEqual(reader.calls.count, 4)
    }

    // MARK: Selection bubble

    func testTheSelectionBubbleRunsOnlyWithExplainTheBubbleAndAccessibility() async throws {
        let watcher = FakeSelectionWatcher()
        let setup = try Setup(test: self, watcher: watcher)
        setup.model.start()
        XCTAssertFalse(watcher.isRunning)
        _ = try await setup.enableExplain()
        XCTAssertFalse(watcher.isRunning, "The bubble is off by default")
        try setup.model.updateToolkit { toolkit in
            var settings = toolkit.explain ?? ExplainSettings()
            settings.selectionBubble = true
            toolkit.explain = settings
        }
        XCTAssertTrue(watcher.isRunning)

        setup.trusted = false
        setup.model.refreshSystemStatus()
        XCTAssertFalse(watcher.isRunning, "Without Accessibility nothing is watched")
        setup.trusted = true
        setup.model.refreshSystemStatus()
        XCTAssertTrue(watcher.isRunning, "Allowing Accessibility starts it without a restart")

        try await setup.model.setFeature(.explain, enabled: false)
        XCTAssertFalse(watcher.isRunning)
        try await setup.model.setFeature(.explain, enabled: true)
        XCTAssertTrue(watcher.isRunning)
        setup.model.shutdown()
        XCTAssertFalse(watcher.isRunning)
        XCTAssertEqual(watcher.starts, 3)
    }

    func testWithoutAccessibilityTheAnswerPanelOffersTheSettingAndNothingIsCopied() async throws {
        let setup = try Setup(test: self)
        let rule = try await setup.enableExplain()
        setup.trusted = false
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.presenter.sessions.last?.phase == .failed(AnswerController.needsAccessibility) }
        XCTAssertEqual(setup.model.answers.recovery, .allowAccessibility)
        XCTAssertEqual(setup.captures, 0)
        XCTAssertTrue(setup.streams.requests.isEmpty)
    }

    func testEditRuleOpensTheEditorOfTheRuleThatFailed() async throws {
        let setup = try Setup(test: self)
        try await setup.model.setFeature(.explain, enabled: true)
        var rule = try XCTUnwrap(setup.model.configuration.rules.first { $0.answersInPanel })
        rule.providerID = nil
        try setup.model.saveRule(rule)
        setup.model.processSelection(ruleID: rule.id)
        try await waitUntil { setup.model.answers.recovery == .editRule }
        setup.model.answers.editRule()
        XCTAssertEqual(setup.model.ruleEditRequest, rule.id)
        XCTAssertEqual(setup.model.toolkit.route, .feature(.explain))
    }

    func testRunningARuleFromItsShortcutHidesTheBubble() async throws {
        let watcher = FakeSelectionWatcher()
        let setup = try Setup(test: self, watcher: watcher)
        let rule = try await setup.enableExplain()
        setup.model.processSelection(ruleID: rule.id)
        XCTAssertEqual(watcher.dismissals, 1)
        try await waitUntil { setup.presenter.sessions.last?.phase == .done(truncated: false) }

        let writing = try XCTUnwrap(setup.model.configuration.rules.first { $0.category == .text && !$0.answersInPanel })
        setup.model.processSelection(ruleID: writing.id)
        XCTAssertEqual(watcher.dismissals, 2)
        try await waitUntil { !setup.model.isProcessing && setup.completions == 1 }
    }

    func testABubbleAnswerReadsTheSelectionAgainWithContextAndNeverCopies() async throws {
        let shown = Self.snapshot("levee", context: nil, element: 1)
        let reader = FakeSelectionReader(.selection(Self.snapshot("levee", context: "The levee held all night.", element: 1)))
        let setup = try Setup(test: self, reader: reader)
        let rule = try await setup.enableExplain()
        let item = BubbleItem(id: rule.id, title: rule.name, symbol: SelectionBubbleItems.answerSymbol, answers: true)
        setup.model.runBubbleItem(item, snapshot: shown)
        try await waitUntil { setup.presenter.sessions.last?.phase == .done(truncated: false) }
        XCTAssertEqual(reader.calls.map(\.includeContext), [true])
        XCTAssertEqual(reader.calls.map(\.pid), [FakeSelectionReader.pid])
        let first = try XCTUnwrap(setup.streams.requests.first?.messages.first?.text)
        XCTAssertTrue(first.contains("levee"), first)
        XCTAssertTrue(first.contains("The levee held all night."), first)
        XCTAssertEqual(setup.presenter.anchors.last, Self.anchor)

        // The selection changed since the bubble appeared: the bubble's text, without context.
        reader.result = .selection(Self.snapshot("flood", context: "The flood came.", element: 2))
        setup.model.runBubbleItem(item, snapshot: shown)
        try await waitUntil { setup.streams.requests.count == 2 }
        let second = try XCTUnwrap(setup.streams.requests.last?.messages.first?.text)
        XCTAssertTrue(second.contains("levee"), second)
        XCTAssertFalse(second.contains("Surrounding text"), second)
        XCTAssertEqual(setup.captures, 0, "No compatibility Copy")
        XCTAssertEqual(setup.clipboardWrites, 0)
    }

    func testABubbleWritingRuleRunsLikeItsShortcut() async throws {
        let setup = try Setup(test: self, reader: FakeSelectionReader(.unavailable))
        _ = try await setup.enableExplain()
        let writing = try XCTUnwrap(setup.model.configuration.rules.first { $0.category == .text && !$0.answersInPanel })
        let item = BubbleItem(id: writing.id, title: writing.name, symbol: SelectionBubbleItems.writingSymbol, answers: false)
        setup.model.runBubbleItem(item, snapshot: Self.snapshot("levee", context: nil, element: 1))
        try await waitUntil { !setup.model.isProcessing && setup.completions == 1 }
        XCTAssertEqual(setup.selection.replacement, "Replaced")
        XCTAssertEqual(setup.captures, 1, "The Writing path reads the selection as its shortcut does")
        XCTAssertTrue(setup.streams.requests.isEmpty)
    }

    private static func snapshot(_ text: String, context: String?, element: Int) -> SelectionSnapshot {
        SelectionSnapshot(text: text, bounds: anchor, endBounds: anchor, context: context, source: nil, isEditable: true,
                          pid: FakeSelectionReader.pid, bundleID: "com.apple.Safari", applicationName: "Safari",
                          fingerprint: SelectionFingerprint(pid: FakeSelectionReader.pid, element: element, location: 0,
                                                            length: text.utf16.count, textHash: text.hashValue))
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition not met", file: file, line: line)
    }
}

@MainActor
private final class Setup {
    let model: AppModel
    let selection = ExplainSelection(text: "river bank", context: "We sat on the river bank until the light went.",
                                     anchor: CGRect(x: 120, y: 480, width: 42, height: 16), applicationName: "Notes",
                                     source: "https://example.com/private/page")
    let streams = Streams()
    let presenter = Presenter()
    var completions = 0
    var captures = 0
    var clipboardWrites = 0
    /// What the injected Accessibility check answers.
    var trusted = true
    var folderChoices = 0
    var cancelsFolderChoice = false
    let notesFolder: URL
    private(set) var installedModelID: String?

    init(test: XCTestCase, installedTextModel: Bool = false, reader: FakeSelectionReader? = nil,
         watcher: (any SelectionWatching)? = nil) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let notesFolder = directory.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        self.notesFolder = notesFolder
        if installedTextModel, let item = LocalModelDescriptor.catalog.first(where: { $0.kind == .text }) {
            // A catalog entry marked as downloaded, with an empty file in place of its weights.
            let folder = directory.appendingPathComponent("Models/\(item.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("weights"))
            try Data("weights".utf8).write(to: folder.appendingPathComponent("installed.txt"))
            installedModelID = item.id
        }
        let streams = streams, presenter = presenter, selection = selection
        var completions: () -> Void = {}
        var captures: () -> Void = {}
        var clipboardWrites: () -> Void = {}
        var trusted: () -> Bool = { true }
        var chooseFolder: () -> URL? = { nil }
        model = AppModel(dataDirectory: directory, registerShortcuts: false,
                         complete: { _, _, _, _ in completions(); return "Replaced" },
                         readKey: { _ in nil }, writeClipboard: { _ in clipboardWrites() },
                         readAccessibility: { trusted() },
                         captureSelection: { captures(); return selection },
                         selectionReader: reader, selectionTarget: { FakeSelectionReader.pid },
                         answerStream: { streams.stream($0) }, answerPresenter: presenter,
                         chooseNotesFolder: { chooseFolder() },
                         selectionWatcher: watcher,
                         errorDisplayDuration: .milliseconds(10),
                         systemStatusTick: { try await Task.sleep(for: .seconds(3_600)) })
        completions = { [weak self] in self?.completions += 1 }
        captures = { [weak self] in self?.captures += 1 }
        clipboardWrites = { [weak self] in self?.clipboardWrites += 1 }
        trusted = { [weak self] in self?.trusted ?? false }
        chooseFolder = { [weak self] in
            guard let self else { return nil }
            self.folderChoices += 1
            return self.cancelsFolderChoice ? nil : notesFolder
        }
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
    }

    func turnOnNotes() throws {
        try model.updateToolkit { toolkit in
            var settings = toolkit.explain ?? ExplainSettings()
            settings.notes = true
            toolkit.explain = settings
        }
    }

    func setHistory(_ enabled: Bool) throws {
        var preferences = model.configuration.preferences
        preferences.historyEnabled = enabled
        try model.savePreferences(preferences)
    }

    /// Turns Explain on and gives the Explain rule the Ollama model.
    func enableExplain() async throws -> Rule {
        try await model.setFeature(.explain, enabled: true)
        var rule = try XCTUnwrap(model.configuration.rules.first { $0.answersInPanel })
        rule.providerID = model.configuration.providers[0].id
        try model.saveRule(rule)
        return rule
    }
}

@MainActor
private final class FakeSelectionWatcher: SelectionWatching {
    private(set) var isRunning = false
    private(set) var starts = 0
    private(set) var dismissals = 0
    func start() { isRunning = true; starts += 1 }
    func stop() { isRunning = false }
    func dismiss() { dismissals += 1 }
}

private final class FakeSelectionReader: SelectionReading, @unchecked Sendable {
    static let pid: pid_t = 4242
    struct Call { var pid: pid_t; var maxCharacters: Int; var includeContext: Bool }
    private let lock = NSLock()
    private var current: SelectionReadResult
    private var recorded: [Call] = []
    init(_ result: SelectionReadResult) { current = result }
    var result: SelectionReadResult {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    var calls: [Call] { lock.withLock { recorded } }
    func read(pid: pid_t, maxCharacters: Int, includeContext: Bool) async -> SelectionReadResult {
        lock.withLock {
            recorded.append(Call(pid: pid, maxCharacters: maxCharacters, includeContext: includeContext))
            return current
        }
    }
}

@MainActor
private final class ExplainSelection: CapturedTextSelection {
    let text: String
    let context: String?
    let anchor: CGRect?
    let applicationName: String?
    let source: String?
    var replacement: String?
    init(text: String, context: String?, anchor: CGRect?, applicationName: String?, source: String?) {
        self.text = text; self.context = context; self.anchor = anchor
        self.applicationName = applicationName; self.source = source
    }
    func replace(with text: String) async throws { replacement = text }
}

@MainActor
private final class Presenter: AnswerPresenting {
    var shown: [AnswerSession] = []
    var anchors: [CGRect?] = []
    var sessions: [AnswerSession] = []
    var closed = 0
    var isKey = false
    var isPinned = false
    func show(_ session: AnswerSession, anchor: CGRect?, pointer: CGPoint) {
        shown.append(session); sessions.append(session); anchors.append(anchor)
    }
    func update(_ session: AnswerSession) { sessions.append(session) }
    func close() { closed += 1 }
}

@MainActor
private final class Streams {
    var requests: [AnswerRequest] = []
    /// Streams wait for `release` instead of answering.
    var hangs = false
    var failure: Error?
    let termination = Terminations()
    private var held: [AsyncThrowingStream<AnswerEvent, Error>.Continuation] = []
    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error> {
        requests.append(request)
        let termination = termination
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AnswerEvent.self, throwing: Error.self)
        continuation.onTermination = { _ in termination.record() }
        if hangs { held.append(continuation) }
        else if let failure { continuation.finish(throwing: failure) }
        else { Self.answer(continuation) }
        return stream
    }

    /// Answers the streams that wait.
    func release() {
        held.forEach(Self.answer)
        held = []
    }

    private static func answer(_ continuation: AsyncThrowingStream<AnswerEvent, Error>.Continuation) {
        continuation.yield(.text("A raised strip of land along a river."))
        continuation.finish()
    }
}

private final class Terminations: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
