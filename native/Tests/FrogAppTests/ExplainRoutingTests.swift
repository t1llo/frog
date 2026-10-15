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
    private(set) var installedModelID: String?

    init(test: XCTestCase, installedTextModel: Bool = false) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
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
        model = AppModel(dataDirectory: directory, registerShortcuts: false,
                         complete: { _, _, _, _ in completions(); return "Replaced" },
                         readKey: { _ in nil }, writeClipboard: { _ in },
                         captureSelection: { captures(); return selection },
                         answerStream: { streams.stream($0) }, answerPresenter: presenter)
        completions = { [weak self] in self?.completions += 1 }
        captures = { [weak self] in self?.captures += 1 }
        try model.saveProvider(ProviderConfiguration(kind: .ollama), apiKey: nil, clearKey: false)
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
    var hangs = false
    let termination = Terminations()
    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error> {
        requests.append(request)
        let hangs = hangs, termination = termination
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in termination.record() }
            guard !hangs else { return }
            continuation.yield(.text("A raised strip of land along a river."))
            continuation.finish()
        }
    }
}

private final class Terminations: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
