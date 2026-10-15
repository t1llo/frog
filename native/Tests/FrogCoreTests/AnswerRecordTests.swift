import XCTest
@testable import FrogCore

final class AnswerRecordTests: XCTestCase {
    private func answered(context: String? = "We sat on the river bank until the light went.") -> AnswerSession {
        var session = AnswerSession(rule: Rule(name: "Explain", instructions: "Explain the selection."), modelName: "gpt-5-mini",
                                    modelLabel: "gpt-5-mini · OpenAI", selection: "river bank", context: context,
                                    application: "Safari", source: "https://example.com/page", replyLanguage: "English")
        session.apply(.text("Land along a river."))
        session.complete()
        return session
    }

    func testAnEntryKeepsTheSelectionTheFirstAnswerAndTheFollowUps() throws {
        var session = answered()
        let id = UUID()
        session.historyEntryID = id
        var entry = HistoryEntry(answer: session, providerName: "OpenAI", model: "gpt-5-mini")
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.category, .text)
        XCTAssertEqual(entry.originalText, "river bank")
        XCTAssertEqual(entry.processedText, "Land along a river.")
        XCTAssertEqual(entry.ruleName, "Explain")
        XCTAssertEqual(entry.providerName, "OpenAI")
        XCTAssertEqual(entry.model, "gpt-5-mini")
        XCTAssertEqual(entry.answer, AnswerRecord(context: "We sat on the river bank until the light went.", application: "Safari",
                                                  source: "https://example.com/page", followUps: []))

        try session.beginFollowUp("And a bank for money?", instructions: "Explain the selection.")
        session.apply(.text("A place that keeps money."))
        session.complete()
        entry.updateAnswer(from: session)
        XCTAssertEqual(entry.answer?.followUps, [AnswerTurn(question: "And a bank for money?", answer: "A place that keeps money.")])
        XCTAssertEqual(entry.processedText, "Land along a river.", "The first answer stays the result")
        XCTAssertEqual(entry.answer?.context, "We sat on the river bank until the light went.")

        XCTAssertNil(HistoryEntry(answer: answered(context: " river bank \n"), providerName: "", model: "").answer?.context,
                     "Context that only repeats the selection was not sent")
        XCTAssertNotEqual(HistoryEntry(answer: answered(), providerName: "", model: "").id, id, "A session without an entry gets a new id")
    }

    func testHistoryWrittenBeforeAnswersStillLoadsAndAnswersRoundTrip() throws {
        let old = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","timestamp":700000000,"originalText":"Original","processedText":"Result",\
        "ruleName":"Proofread","providerName":"Local","model":"fixture","targetLanguage":"","category":"text"}]
        """
        let entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(old.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].answer)
        XCTAssertEqual(entries[0].processedText, "Result")

        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entries[0])) as? [String: Any])
        XCTAssertNil(plain["answer"], "An entry without an answer writes no answer key")

        var session = answered()
        try session.beginFollowUp("Why?", instructions: "Explain the selection.")
        session.apply(.text("Because."))
        session.complete()
        let entry = HistoryEntry(answer: session, providerName: "OpenAI", model: "gpt-5-mini")
        XCTAssertEqual(try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry)), entry)
    }
}
