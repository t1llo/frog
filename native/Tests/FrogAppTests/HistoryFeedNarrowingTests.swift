import FrogCore
import XCTest
@testable import FrogApp

final class HistoryFeedNarrowingTests: XCTestCase {
    func testNarrowingTheSortedFeedListsWhatBuildingItFilteredDoes() {
        let moment = Date(timeIntervalSince1970: 100)
        var dictated = HistoryEntry(timestamp: moment, originalText: "spoken words", processedText: "Spoken words.", ruleName: "Dictation", providerName: "Local", model: "fixture")
        dictated.category = .audio
        let saved = [
            HistoryEntry(timestamp: Date(timeIntervalSince1970: 10), originalText: "Original", processedText: "Result", ruleName: "Proofread", providerName: "Local", model: "fixture"),
            dictated,
            // The same moment as the dictation, so the order rests on the tie-break alone.
            HistoryEntry(timestamp: moment, originalText: "Other", processedText: "Shared words", ruleName: "Rewrite", providerName: "Remote", model: "fixture"),
        ]
        let all = HistoryFeed.items(saved)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.timestamp), all.map(\.timestamp).sorted(by: >), "The feed is newest first")
        let filters: [HistoryFilter?] = [nil] + HistoryFilter.allCases.map { Optional($0) }
        for filter in filters {
            for search in ["", "  words ", "Remote", "no such text"] {
                XCTAssertEqual(HistoryFeed.narrowed(all, filter: filter, search: search),
                               HistoryFeed.items(saved, filter: filter, search: search), "\(filter?.title ?? "All") · “\(search)”")
            }
        }
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: nil, search: ""), all)
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: .audio, search: "").map(\.id), [dictated.id])
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: nil, search: "words").count, 2)
    }

    private func answerEntry() -> HistoryEntry {
        var entry = HistoryEntry(timestamp: Date(timeIntervalSince1970: 300), originalText: "river bank", processedText: "Land along a river.",
                                 ruleName: "Explain", providerName: "OpenAI", model: "gpt-5-mini")
        entry.category = .text
        entry.answer = AnswerRecord(context: "We sat on the river bank until dusk.", application: "Safari", source: "https://example.com/walks",
                                    followUps: [AnswerTurn(question: "And a bank for money?", answer: "A place that keeps savings.")])
        return entry
    }

    func testAnswersHaveTheirOwnFilterAndTextKeepsWritingResults() {
        let writing = HistoryEntry(timestamp: Date(timeIntervalSince1970: 10), originalText: "Original", processedText: "Result",
                                   ruleName: "Proofread", providerName: "Local", model: "fixture")
        let answer = answerEntry()
        let all = HistoryFeed.items([writing, answer])
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: .answers, search: "").map(\.id), [answer.id])
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: .text, search: "").map(\.id), [writing.id])
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: nil, search: "").map(\.id), [answer.id, writing.id])
    }

    func testSearchFindsWhatAnAnswerKeeps() {
        let answer = answerEntry()
        let all = HistoryFeed.items([answer])
        for query in ["until dusk", "safari", "example.com/walks", "bank for money", "keeps savings"] {
            XCTAssertEqual(HistoryFeed.narrowed(all, filter: nil, search: query).map(\.id), [answer.id], query)
        }
        XCTAssertTrue(HistoryFeed.narrowed(all, filter: .answers, search: "no such text").isEmpty)
    }

    func testTheAnswersFilterShowsWhileExplainIsOnOrAnswersRemain() {
        XCTAssertEqual(HistoryFilter.visible(explainEnabled: false, hasAnswers: false), [.text, .audio])
        XCTAssertEqual(HistoryFilter.visible(explainEnabled: true, hasAnswers: false), [.text, .answers, .audio])
        XCTAssertEqual(HistoryFilter.visible(explainEnabled: false, hasAnswers: true), [.text, .answers, .audio])
        XCTAssertEqual(HistoryFilter.visible(explainEnabled: true, hasAnswers: true), [.text, .answers, .audio])
    }
}
