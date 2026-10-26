import FrogCore
import XCTest
@testable import FrogApp

final class HistoryFeedNarrowingTests: XCTestCase {
    func testNarrowingTheMergedFeedListsWhatBuildingItFilteredDoes() {
        let moment = Date(timeIntervalSince1970: 100)
        var dictated = HistoryEntry(timestamp: moment, originalText: "spoken words", processedText: "Spoken words.", ruleName: "Dictation", providerName: "Local", model: "fixture")
        dictated.category = .audio
        let saved = [
            HistoryEntry(timestamp: Date(timeIntervalSince1970: 10), originalText: "Original", processedText: "Result", ruleName: "Proofread", providerName: "Local", model: "fixture"),
            dictated,
            // The same moment as the dictation, so the order rests on the tie-break alone.
            HistoryEntry(timestamp: moment, originalText: "Other", processedText: "Shared words", ruleName: "Rewrite", providerName: "Remote", model: "fixture"),
        ]
        let secret = ClipboardHistoryEntry(text: "A synthetic secret", isSensitive: true, timestamp: Date(timeIntervalSince1970: 50))
        let clipboard = [ClipboardHistoryEntry(text: "Ordinary words", timestamp: Date(timeIntervalSince1970: 200)), secret]
        let all = HistoryFeed.items(saved: saved, clipboard: clipboard)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all.map(\.timestamp), all.map(\.timestamp).sorted(by: >), "The merged feed is newest first")
        let filters: [HistoryFilter?] = [nil] + HistoryFilter.allCases.map { Optional($0) }
        let revealedSets: [Set<UUID>] = [[], [secret.id]]
        for filter in filters {
            for search in ["", "  words ", "synthetic secret", "Clipboard", "no such text"] {
                for revealed in revealedSets {
                    XCTAssertEqual(HistoryFeed.narrowed(all, filter: filter, search: search, revealed: revealed),
                                   HistoryFeed.items(saved: saved, clipboard: clipboard, filter: filter, search: search, revealed: revealed),
                                   "\(filter?.title ?? "All") · “\(search)” · \(revealed.count) revealed")
                }
            }
        }
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: nil, search: "", revealed: []), all)
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: .audio, search: "", revealed: []).map(\.id), [dictated.id])
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: nil, search: "words", revealed: []).count, 3)
        XCTAssertTrue(HistoryFeed.narrowed(all, filter: nil, search: "synthetic secret", revealed: []).isEmpty, "Hidden text must not match before it is revealed")
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: nil, search: "synthetic secret", revealed: [secret.id]).map(\.id), [secret.id])
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
        let all = HistoryFeed.items(saved: [writing, answer], clipboard: [])
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: .answers, search: "", revealed: []).map(\.id), [answer.id])
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: .text, search: "", revealed: []).map(\.id), [writing.id])
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: nil, search: "", revealed: []).map(\.id), [answer.id, writing.id])
        XCTAssertEqual(all.first?.title, "Explain")
        XCTAssertEqual(all.first?.text, "Land along a river.")
    }

    func testSearchFindsWhatAnAnswerKeepsButNotHiddenCopiedText() {
        let answer = answerEntry()
        let secret = ClipboardHistoryEntry(text: "savings at the bank until dusk", isSensitive: true, timestamp: Date(timeIntervalSince1970: 400))
        let all = HistoryFeed.items(saved: [answer], clipboard: [secret])
        for query in ["until dusk", "safari", "example.com/walks", "bank for money", "keeps savings"] {
            XCTAssertEqual(HistoryFeed.narrowed(all, filter: nil, search: query, revealed: []).map(\.id), [answer.id], query)
        }
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: nil, search: "keeps savings", revealed: [secret.id]).map(\.id), [answer.id])
        XCTAssertEqual(HistoryFeed.narrowed(all, filter: nil, search: "savings", revealed: [secret.id]).map(\.id), [secret.id, answer.id])
        XCTAssertTrue(HistoryFeed.narrowed(all, filter: .answers, search: "no such text", revealed: []).isEmpty)
    }

    func testTheAnswersFilterShowsWhileExplainIsOnOrAnswersRemain() {
        XCTAssertEqual(HistoryFilter.visible(explainEnabled: false, hasAnswers: false), [.text, .audio])
        XCTAssertEqual(HistoryFilter.visible(explainEnabled: true, hasAnswers: false), [.text, .answers, .audio])
        XCTAssertEqual(HistoryFilter.visible(explainEnabled: false, hasAnswers: true), [.text, .answers, .audio])
        XCTAssertEqual(HistoryFilter.visible(explainEnabled: true, hasAnswers: true), [.text, .answers, .audio])
    }
}
