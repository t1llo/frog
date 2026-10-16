import XCTest
import FrogCore
@testable import FrogApp

@MainActor
final class AnswerControllerTests: XCTestCase {
    private let local = ProviderConfiguration(id: AppModel.localProviderID, name: "Qwen3 4B", kind: .compatible, model: "qwen3-4b")
    private let cloud = ProviderConfiguration(name: "OpenAI", kind: .openAI, model: "gpt-5-mini")

    func testAnAnswerStreamsIntoThePanelAndCountsOnce() async throws {
        let fixture = Fixture(provider: local)
        fixture.streams.scripts = [[.event(.loading("Qwen3 4B")), .event(.text("A ")), .event(.text("bank."))]]
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "bank"))
        try await waitUntilSettled(fixture.controller)

        let phases = fixture.presenter.phases
        XCTAssertEqual(phases.first, .waiting)
        let loading = try XCTUnwrap(phases.firstIndex(of: .loading("Qwen3 4B")))
        let streaming = try XCTUnwrap(phases.firstIndex(of: .streaming))
        XCTAssertLessThan(loading, streaming)
        XCTAssertEqual(phases.last, .done(truncated: false))
        XCTAssertEqual(fixture.controller.session?.turns, [AnswerTurn(question: "", answer: "A bank.")])
        XCTAssertEqual(fixture.controller.session?.modelLabel, "Qwen3 4B · Frog")
        XCTAssertEqual(fixture.calls.statistics, [.local])
        XCTAssertEqual(fixture.streams.requests.count, 1)
        XCTAssertEqual(fixture.streams.requests.first?.isFrogLocal, true)
        XCTAssertTrue(fixture.calls.reports.isEmpty)
    }

    func testReasoningIsHiddenAndAnAnswerOfOnlyReasoningFails() async throws {
        let fixture = Fixture(provider: cloud)
        fixture.streams.scripts = [[.event(.text("<think>x</think>Answer"))], [.event(.text("<think>only</think>"))], []]
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "bank"))
        try await waitUntilSettled(fixture.controller)
        XCTAssertEqual(fixture.controller.session?.turns.last?.answer, "Answer")
        XCTAssertFalse(fixture.presenter.sessions.contains { $0.partial.contains("think") })

        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "bank"))
        try await waitUntilSettled(fixture.controller)
        XCTAssertEqual(fixture.controller.session?.phase, .failed(ReasoningFilter.onlyReasoning))
        XCTAssertEqual(fixture.controller.recovery, .retry)

        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "bank"))
        try await waitUntilSettled(fixture.controller)
        XCTAssertEqual(fixture.controller.session?.phase, .failed("The model returned no text."))
        XCTAssertEqual(fixture.calls.reports.count, 2)
        XCTAssertEqual(fixture.calls.statistics.count, 1)
    }

    func testChecksFailInThePanelBeforeAnyRequest() async throws {
        let fixture = Fixture(provider: local)
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: " \n "))
        XCTAssertEqual(fixture.controller.session?.phase, .failed("Select some text first."))
        XCTAssertNil(fixture.controller.recovery)

        let long = String(repeating: "a", count: 12_001)
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: long))
        XCTAssertEqual(fixture.controller.session?.phase, .failed(AnswerPrompt.selectionTooLong(limit: 12_000)))
        XCTAssertEqual(fixture.controller.recovery, .editRule)

        let unresolved = Fixture(provider: local, resolveError: "Choose a text model for Explain.")
        var edited: UUID?
        unresolved.controller.onEditRule = { edited = $0 }
        let rule = Rule.explainPreset
        unresolved.controller.start(rule: rule, capture: AnswerCapture(text: "bank"))
        XCTAssertEqual(unresolved.controller.session?.phase, .failed("Choose a text model for Explain."))
        XCTAssertEqual(unresolved.controller.recovery, .editRule)
        unresolved.controller.editRule()
        XCTAssertEqual(edited, rule.id)

        for fixture in [fixture, unresolved] {
            XCTAssertTrue(fixture.streams.requests.isEmpty)
            XCTAssertEqual(fixture.presenter.shown.count, fixture === unresolved ? 1 : 2)
            XCTAssertEqual(fixture.calls.reports.count, fixture.presenter.shown.count)
        }
        XCTAssertEqual(unresolved.calls.reports.first?.localizedDescription, "Choose a text model for Explain.")
    }

    func testALongSelectionStreamsFromACloudModel() async throws {
        let fixture = Fixture(provider: cloud)
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: String(repeating: "a", count: 12_001)))
        try await waitUntilSettled(fixture.controller)
        XCTAssertEqual(fixture.streams.requests.count, 1)
        XCTAssertEqual(fixture.streams.requests.first?.apiKey, "fixture-key")
        XCTAssertEqual(fixture.streams.requests.first?.isFrogLocal, false)
        XCTAssertEqual(fixture.controller.session?.modelLabel, "gpt-5-mini · OpenAI")
        XCTAssertEqual(fixture.calls.statistics, [.remote])
    }

    func testStopKeepsPartialTextAndRetrySendsTheSameMessages() async throws {
        let fixture = Fixture(provider: cloud)
        fixture.streams.scripts = [[.event(.text("A ")), .hang], [.event(.text("Full answer"))]]
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "bank"))
        try await waitUntil { fixture.controller.session?.partial == "A " }
        fixture.controller.stop()
        XCTAssertEqual(fixture.controller.session?.phase, .stopped)
        XCTAssertEqual(fixture.controller.session?.statusLine, "Stopped")
        XCTAssertEqual(fixture.controller.session?.partial, "A ")
        XCTAssertEqual(fixture.controller.recovery, .retry, "A stopped answer offers Retry")
        try await waitUntil { fixture.streams.terminated(0) }
        XCTAssertTrue(fixture.calls.records.isEmpty)
        XCTAssertTrue(fixture.calls.statistics.isEmpty)

        fixture.controller.retry()
        XCTAssertNil(fixture.controller.recovery)
        try await waitUntilSettled(fixture.controller)
        XCTAssertEqual(fixture.streams.requests.count, 2)
        XCTAssertEqual(fixture.streams.requests[1].messages, fixture.streams.requests[0].messages)
        XCTAssertEqual(fixture.controller.session?.turns, [AnswerTurn(question: "", answer: "Full answer")])
        XCTAssertEqual(fixture.calls.records.count, 1)
    }

    func testFollowUpsAlternateAndStopAfterTen() async throws {
        let fixture = Fixture(provider: cloud)
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "bank"))
        try await waitUntilSettled(fixture.controller)
        for index in 1...AnswerPrompt.maximumFollowUps {
            XCTAssertNil(fixture.controller.ask("Question \(index)?"))
            try await waitUntilSettled(fixture.controller)
        }
        let roles = try XCTUnwrap(fixture.streams.requests.last?.messages.map(\.role))
        XCTAssertEqual(roles.count, 1 + 2 * AnswerPrompt.maximumFollowUps)
        for (index, role) in roles.enumerated() { XCTAssertEqual(role, index.isMultiple(of: 2) ? .user : .assistant) }
        XCTAssertEqual(fixture.streams.requests.last?.messages.last?.text, "Question 10?")

        XCTAssertEqual(fixture.controller.ask("One more?"), AnswerSession.startNewAnswer)
        XCTAssertEqual(fixture.controller.followUpMessage, AnswerSession.startNewAnswer)
        XCTAssertEqual(fixture.streams.requests.count, 1 + AnswerPrompt.maximumFollowUps)
        XCTAssertEqual(fixture.controller.session?.phase, .done(truncated: false))
    }

    func testStartingAnotherAnswerCancelsTheRunningStream() async throws {
        let fixture = Fixture(provider: cloud)
        fixture.streams.scripts = [[.hang], [.event(.text("Second"))]]
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "first"))
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "second"))
        try await waitUntilSettled(fixture.controller)
        try await waitUntil { fixture.streams.terminated(0) }
        XCTAssertEqual(fixture.controller.session?.selection, "second")
        XCTAssertEqual(fixture.controller.session?.turns.last?.answer, "Second")
        XCTAssertEqual(fixture.calls.statistics.count, 1)
    }

    func testAnErrorMidStreamShowsRetryAndIsNotRecorded() async throws {
        let fixture = Fixture(provider: cloud)
        fixture.streams.scripts = [[.event(.text("Part")), .fail(FrogError.message("The provider is unavailable."))]]
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "bank"))
        try await waitUntilSettled(fixture.controller)
        XCTAssertEqual(fixture.controller.session?.phase, .failed("The provider is unavailable."))
        XCTAssertEqual(fixture.presenter.phases.last, .failed("The provider is unavailable."))
        XCTAssertEqual(fixture.controller.recovery, .retry)
        XCTAssertEqual(fixture.calls.reports.map(\.localizedDescription), ["The provider is unavailable."])
        XCTAssertTrue(fixture.calls.records.isEmpty)
        XCTAssertTrue(fixture.calls.statistics.isEmpty)
    }

    func testTheFirstTurnIsRecordedAndFollowUpsUpdateItUntilRefused() async throws {
        let entry = UUID()
        let fixture = Fixture(provider: cloud, recordID: entry, updateResults: [true, false])
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "bank"))
        try await waitUntilSettled(fixture.controller)
        XCTAssertEqual(fixture.calls.records.count, 1)
        XCTAssertEqual(fixture.calls.records.first?.turns.count, 1)
        XCTAssertEqual(fixture.controller.session?.historyEntryID, entry)
        for question in ["Why?", "How?", "Where?"] {
            fixture.controller.ask(question)
            try await waitUntilSettled(fixture.controller)
        }
        XCTAssertEqual(fixture.calls.updates.map(\.turns.count), [2, 3], "A refused update ends updating")
        XCTAssertEqual(fixture.calls.records.count, 1)
        XCTAssertEqual(fixture.calls.statistics.count, 1)
    }

    func testCopyTakesThePartialAnswerWhileStreamingAndTheWholeOneAfter() async throws {
        let fixture = Fixture(provider: cloud)
        fixture.streams.scripts = [[.event(.text("Partial ")), .hang], [.event(.text("Full answer"))]]
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "bank"))
        try await waitUntil { fixture.controller.session?.partial == "Partial " }
        XCTAssertTrue(fixture.controller.copyLatest())
        fixture.controller.stop()
        fixture.controller.retry()
        try await waitUntilSettled(fixture.controller)
        XCTAssertTrue(fixture.controller.copyLatest())
        XCTAssertEqual(fixture.calls.copies, ["Partial", "Full answer"])

        let waiting = Fixture(provider: cloud)
        waiting.streams.scripts = [[.hang]]
        waiting.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "bank"))
        XCTAssertFalse(waiting.controller.copyLatest(), "Nothing to copy, so the panel confirms nothing")
        XCTAssertTrue(waiting.calls.copies.isEmpty)
    }

    func testAQuestionAskedWhileTheAnswerRunsWaitsAndTheRequestToWaitEndsWithTheTurn() async throws {
        let fixture = Fixture(provider: cloud)
        fixture.streams.scripts = [[.event(.text("A ")), .hang]]
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "bank"))
        try await waitUntil { fixture.controller.session?.partial == "A " }
        XCTAssertEqual(fixture.controller.ask("And a levee?"), AnswerSession.waitForAnswer)
        XCTAssertEqual(fixture.streams.requests.count, 1)
        fixture.controller.stop()
        XCTAssertNil(fixture.controller.followUpMessage)
        XCTAssertNil(fixture.controller.ask("And a levee?"), "A stopped answer with text can be asked about")
        try await waitUntilSettled(fixture.controller)
        XCTAssertEqual(fixture.streams.requests.last?.messages.last?.text, "And a levee?")
    }

    func testTheSourceIsNeverSent() async throws {
        let fixture = Fixture(provider: cloud)
        let source = "https://example.com/private/page"
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "bank", context: "The river bank flooded.",
                                                                              application: "Safari", source: source))
        try await waitUntilSettled(fixture.controller)
        fixture.controller.ask("And a money bank?")
        try await waitUntilSettled(fixture.controller)
        XCTAssertEqual(fixture.controller.session?.source, source)
        XCTAssertEqual(fixture.streams.requests.count, 2)
        for request in fixture.streams.requests {
            XCTAssertFalse(request.instructions.contains("example.com"))
            XCTAssertFalse(request.messages.contains { $0.text.contains("example.com") })
        }
        XCTAssertTrue(fixture.streams.requests[0].messages[0].text.contains("The river bank flooded."))
    }

    func testTextUpdatesAreThrottledButPhaseChangesAndTheEndAreNot() async throws {
        let fixture = Fixture(provider: cloud, updateInterval: .seconds(60))
        fixture.streams.scripts = [[.event(.text("A")), .event(.text("B")), .event(.text("C"))]]
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "bank"))
        try await waitUntilSettled(fixture.controller)
        XCTAssertEqual(fixture.presenter.phases, [.waiting, .streaming, .done(truncated: false)])
        XCTAssertEqual(fixture.presenter.sessions[1].partial, "A")
        XCTAssertEqual(fixture.presenter.sessions.last?.turns.last?.answer, "ABC")
    }

    func testCloseCancelsTheStreamAndClosesThePanel() async throws {
        let fixture = Fixture(provider: cloud)
        fixture.streams.scripts = [[.hang]]
        fixture.controller.start(rule: .explainPreset, capture: AnswerCapture(text: "bank"))
        fixture.controller.close()
        XCTAssertNil(fixture.controller.session)
        XCTAssertEqual(fixture.presenter.closed, 1)
        try await waitUntil { fixture.streams.terminated(0) }
    }

    // MARK: Helpers

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out", file: file, line: line)
    }

    /// Waits until the running turn has ended, however it ended.
    private func waitUntilSettled(_ controller: AnswerController, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil({
            switch controller.session?.phase {
            case .done, .stopped, .failed, nil: true
            case .loading, .waiting, .thinking, .streaming: false
            }
        }, file: file, line: line)
    }
}

private extension AnswerCapture {
    init(text: String, context: String? = nil, application: String? = nil, source: String? = nil) {
        self.init(text: text, context: context, anchor: nil, application: application, source: source)
    }
}

@MainActor
private final class Fixture {
    let presenter: FakePresenter
    let streams: FakeStreams
    let calls: Calls
    let controller: AnswerController

    init(provider: ProviderConfiguration, resolveError: String? = nil, recordID: UUID? = nil, updateResults: [Bool] = [],
         updateInterval: Duration = .zero) {
        let presenter = FakePresenter(), streams = FakeStreams(), calls = Calls()
        calls.updateResults = updateResults
        self.presenter = presenter; self.streams = streams; self.calls = calls
        controller = AnswerController(
            resolve: { _ in
                if let resolveError { throw FrogError.message(resolveError) }
                return provider
            },
            readKey: { _ in "fixture-key" },
            stream: { streams.stream($0) },
            presenter: presenter,
            modelName: { $0.id == AppModel.localProviderID ? $0.name : $0.modelName($0.model) },
            pointer: { .zero },
            replyLanguage: { "English" },
            report: { calls.reports.append($0) },
            recordStatistics: { calls.statistics.append($0) },
            copy: { calls.copies.append($0) },
            record: { calls.records.append($0); return recordID },
            updateRecord: { session in
                calls.updates.append(session)
                return calls.updateResults.isEmpty ? true : calls.updateResults.removeFirst()
            },
            updateInterval: updateInterval)
    }
}

@MainActor
private final class Calls {
    var reports: [Error] = []
    var statistics: [ActivityRuleKind] = []
    var copies: [String] = []
    var records: [AnswerSession] = []
    var updates: [AnswerSession] = []
    var updateResults: [Bool] = []
}

@MainActor
private final class FakePresenter: AnswerPresenting {
    var shown: [AnswerSession] = []
    /// Every session the panel displayed, in order.
    var sessions: [AnswerSession] = []
    var closed = 0
    var isKey = false
    var isPinned = false
    var phases: [AnswerSession.Phase] { sessions.map(\.phase) }
    func show(_ session: AnswerSession, anchor: CGRect?, pointer: CGPoint) { shown.append(session); sessions.append(session) }
    func update(_ session: AnswerSession) { sessions.append(session) }
    func close() { closed += 1 }
}

/// Streams that play a script per request. `hang` leaves the stream open until it is cancelled.
@MainActor
private final class FakeStreams {
    enum Step { case event(AnswerEvent), fail(Error), hang }
    var scripts: [[Step]] = []
    private(set) var requests: [AnswerRequest] = []
    private var terminations: [Termination] = []

    func terminated(_ index: Int) -> Bool { terminations.indices.contains(index) && terminations[index].happened }

    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<AnswerEvent, Error> {
        requests.append(request)
        let script = scripts.isEmpty ? [.event(.text("Answer"))] : scripts.removeFirst()
        let termination = Termination()
        terminations.append(termination)
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in termination.mark() }
            for step in script {
                switch step {
                case .event(let event): continuation.yield(event)
                case .fail(let error): continuation.finish(throwing: error); return
                case .hang: return
                }
            }
            continuation.finish()
        }
    }
}

private final class Termination: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var happened: Bool { lock.withLock { value } }
    func mark() { lock.withLock { value = true } }
}
