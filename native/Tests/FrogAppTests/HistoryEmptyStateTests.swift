import FrogCore
import XCTest
@testable import FrogApp

final class HistoryEmptyStateTests: XCTestCase {
    private let saved = HistoryEntry(originalText: "Original", processedText: "Result words", ruleName: "Proofread", providerName: "Local", model: "fixture")

    private func state(saved: [HistoryEntry], clipboard: [ClipboardHistoryEntry], filter: HistoryFilter?, search: String = "") -> HistoryEmptyState? {
        let all = HistoryFeed.items(saved: saved, clipboard: clipboard)
        return .describing(all: all, shown: HistoryFeed.narrowed(all, filter: filter, search: search, revealed: []), filter: filter, search: search)
    }

    func testClipboardFilterWithoutCopiedTextExplainsItselfAlthoughSavedHistoryExists() {
        XCTAssertEqual(state(saved: [saved], clipboard: [], filter: .clipboard), .noCopiedText)
        XCTAssertEqual(state(saved: [saved], clipboard: [], filter: .clipboard, search: "  \n"), .noCopiedText, "The feed trims the search, so spaces alone are no search")
        XCTAssertEqual(state(saved: [saved], clipboard: [], filter: .clipboard, search: "words"), .noMatches)
    }

    func testNoMatchesIsForAFilterOrSearchThatLeavesNothingOfAnExistingFeed() {
        let copied = ClipboardHistoryEntry(text: "Ordinary copied text")
        XCTAssertNil(state(saved: [saved], clipboard: [copied], filter: nil))
        XCTAssertNil(state(saved: [saved], clipboard: [copied], filter: .clipboard))
        XCTAssertEqual(state(saved: [saved], clipboard: [copied], filter: nil, search: "no such text"), .noMatches)
        XCTAssertEqual(state(saved: [saved], clipboard: [copied], filter: .clipboard, search: "no such text"), .noMatches)
        XCTAssertEqual(state(saved: [saved], clipboard: [copied], filter: .audio), .noMatches)
    }

    func testAnEmptyFeedSaysWhatWillAppear() {
        XCTAssertEqual(state(saved: [], clipboard: [], filter: nil), .noHistory)
        XCTAssertEqual(state(saved: [], clipboard: [], filter: .text, search: "words"), .noHistory)
        XCTAssertEqual(state(saved: [], clipboard: [], filter: .clipboard), .noCopiedText)
    }
}
