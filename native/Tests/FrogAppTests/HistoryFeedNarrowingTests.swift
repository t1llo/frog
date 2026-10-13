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
}
