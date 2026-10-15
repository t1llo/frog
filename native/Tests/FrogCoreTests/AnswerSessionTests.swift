import XCTest
@testable import FrogCore

final class AnswerSessionTests: XCTestCase {
    private let instructions = "Explain the selection."

    func testEventsSetPhaseAndText() {
        var session = makeSession()
        XCTAssertEqual(session.phase, .waiting)
        session.apply(.loading("Qwen3 4B"))
        XCTAssertEqual(session.phase, .loading("Qwen3 4B"))
        session.apply(.thinking)
        XCTAssertEqual(session.phase, .thinking)
        XCTAssertEqual(session.partial, "")
        session.apply(.text("Hel"))
        session.apply(.thinking)
        session.apply(.text("lo"))
        XCTAssertEqual(session.phase, .streaming)
        XCTAssertEqual(session.partial, "Hello")
        session.apply(.truncated)
        XCTAssertEqual(session.complete(), AnswerTurn(question: "", answer: "Hello"))
        XCTAssertEqual(session.phase, .done(truncated: true))
        XCTAssertEqual(session.statusLine, "The answer reached the length limit.")
        XCTAssertEqual(session.turns, [AnswerTurn(question: "", answer: "Hello")])
        XCTAssertEqual(session.partial, "")
        session.apply(.text("late"))
        XCTAssertEqual(session.partial, "", "Events after the end are ignored")
    }

    func testFollowUpsGrowTheConversationUpToTen() throws {
        var session = answered()
        XCTAssertNil(session.followUpBlock)
        for index in 1...AnswerPrompt.maximumFollowUps {
            try session.beginFollowUp("  Question \(index)?\n", instructions: instructions)
            XCTAssertEqual(session.pendingQuestion, "Question \(index)?")
            XCTAssertEqual(session.phase, .waiting)
            XCTAssertEqual(session.followUpBlock, "Wait for the answer to finish")
            XCTAssertEqual(session.messages.last, ChatMessage(role: .user, text: "Question \(index)?"))
            session.apply(.text("Answer \(index)"))
            XCTAssertEqual(session.complete(), AnswerTurn(question: "Question \(index)?", answer: "Answer \(index)"))
        }
        XCTAssertEqual(session.followUpBlock, "Start a new answer to ask more")
        XCTAssertThrowsError(try session.beginFollowUp("Question 11?", instructions: instructions)) {
            XCTAssertEqual($0.localizedDescription, "Start a new answer to ask more")
        }
    }

    func testQuestionTexts() {
        var session = answered()
        XCTAssertThrowsError(try session.beginFollowUp(" \n ", instructions: instructions)) {
            XCTAssertEqual($0.localizedDescription, "Type a question first.")
        }
        XCTAssertThrowsError(try session.beginFollowUp(String(repeating: "q", count: 2_001), instructions: instructions)) {
            XCTAssertEqual($0.localizedDescription, "Ask a shorter question (at most 2,000 characters).")
        }
        XCTAssertNoThrow(try session.beginFollowUp(String(repeating: "q", count: 2_000), instructions: instructions))
    }

    func testLongConversationDropsContextFirstThenRefuses() throws {
        var session = makeSession(context: String(repeating: "c", count: 5_000))
        XCTAssertTrue(session.firstMessage.contains("Surrounding text:"))
        session.apply(.text(String(repeating: "a", count: 196_000)))
        session.complete()
        XCTAssertNil(session.followUpBlock)
        try session.beginFollowUp("Why?", instructions: instructions)
        XCTAssertTrue(session.contextDropped)
        XCTAssertFalse(session.firstMessage.contains("Surrounding text:"))
        XCTAssertFalse(session.messages[0].text.contains("ccc"))
        session.apply(.text(String(repeating: "b", count: 5_000)))
        session.complete()
        XCTAssertEqual(session.followUpBlock, "Start a new answer to ask more")
        XCTAssertThrowsError(try session.beginFollowUp("Short?", instructions: instructions)) {
            XCTAssertEqual($0.localizedDescription, "Start a new answer to ask more")
        }
        XCTAssertNil(session.pendingQuestion)
        XCTAssertEqual(session.phase, .done(truncated: false))
    }

    func testStopKeepsTextAndRetryClearsIt() throws {
        var session = makeSession()
        session.apply(.text("Part"))
        session.stop()
        XCTAssertEqual(session.partial, "Part")
        XCTAssertNil(session.followUpBlock, "A stopped answer with text can be asked about")
        try session.beginFollowUp("More?", instructions: instructions)
        XCTAssertEqual(session.turns, [AnswerTurn(question: "", answer: "Part")])
        session.apply(.text("Half an answer"))
        session.fail("The connection was lost.")
        XCTAssertEqual(session.followUpBlock, "Wait for the answer to finish")
        session.resetForRetry()
        XCTAssertEqual(session.partial, "")
        XCTAssertEqual(session.phase, .waiting)
        XCTAssertEqual(session.pendingQuestion, "More?")
        XCTAssertEqual(session.messages.last, ChatMessage(role: .user, text: "More?"))

        var empty = makeSession()
        empty.stop()
        XCTAssertEqual(empty.followUpBlock, "Wait for the answer to finish")
    }

    func testStatusLineForEveryPhase() {
        var session = makeSession()
        let expected: [(AnswerSession.Phase, String?)] = [
            (.loading("Qwen3 4B"), "Loading Qwen3 4B…"),
            (.waiting, "Waiting for gpt-5-mini…"),
            (.thinking, "Thinking…"),
            (.streaming, nil),
            (.done(truncated: true), "The answer reached the length limit."),
            (.done(truncated: false), nil),
            (.stopped, "Stopped"),
            (.failed("Select some text first."), "Select some text first.")
        ]
        for (phase, line) in expected {
            session.phase = phase
            XCTAssertEqual(session.statusLine, line, "\(phase)")
        }
    }

    private func makeSession(context: String? = "We had a picnic on the river bank.") -> AnswerSession {
        AnswerSession(rule: Rule(name: "Explain", instructions: instructions), modelName: "gpt-5-mini", modelLabel: "gpt-5-mini · OpenAI",
                      selection: "river bank", context: context, application: "Safari", source: nil, replyLanguage: "English")
    }

    private func answered() -> AnswerSession {
        var session = makeSession()
        session.apply(.text("A bank of a river."))
        session.complete()
        return session
    }
}
