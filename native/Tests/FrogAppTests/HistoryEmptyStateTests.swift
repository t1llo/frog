import FrogCore
import XCTest
@testable import FrogApp

final class HistoryEmptyStateTests: XCTestCase {
    private let saved = HistoryEntry(originalText: "Original", processedText: "Result words", ruleName: "Proofread", providerName: "Local", model: "fixture")

    private func state(_ entries: [HistoryEntry], filter: HistoryFilter?, search: String = "") -> HistoryEmptyState? {
        let all = HistoryFeed.items(entries)
        return .describing(all: all, shown: HistoryFeed.narrowed(all, filter: filter, search: search), filter: filter, search: search)
    }

    func testNoMatchesIsForAFilterOrSearchThatLeavesNothingOfAnExistingFeed() {
        XCTAssertNil(state([saved], filter: nil))
        XCTAssertNil(state([saved], filter: .text, search: "  words "))
        XCTAssertEqual(state([saved], filter: nil, search: "no such text"), .noMatches)
        XCTAssertEqual(state([saved], filter: .audio), .noMatches)
    }

    func testTheAnswersFilterWithoutAnswersSaysHowTheyAppear() {
        XCTAssertEqual(state([saved], filter: .answers), .noAnswers)
        XCTAssertEqual(state([saved], filter: .answers, search: " "), .noAnswers, "The feed trims the search, so spaces alone are no search")
        XCTAssertEqual(state([saved], filter: .answers, search: "words"), .noMatches)
        XCTAssertEqual(state([], filter: .answers), .noAnswers)
        var answer = HistoryEntry(originalText: "bank", processedText: "Land along a river.", ruleName: "Explain", providerName: "", model: "")
        answer.answer = AnswerRecord(context: nil, application: nil, source: nil, followUps: [])
        XCTAssertNil(state([saved, answer], filter: .answers))
        XCTAssertEqual(state([saved, answer], filter: .answers, search: "no such text"), .noMatches)
    }

    func testAnEmptyFeedSaysWhatWillAppear() {
        XCTAssertEqual(state([], filter: nil), .noHistory)
        XCTAssertEqual(state([], filter: .text, search: "words"), .noHistory)
        XCTAssertEqual(state([], filter: .audio), .noHistory)
    }
}
