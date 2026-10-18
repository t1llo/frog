import XCTest
import SwiftUI
import FrogCore
@testable import FrogApp

/// The bubble's sizes and pointer coordinates, measured without a window.
@MainActor
final class SelectionBubbleLayoutTests: XCTestCase {
    private func item(_ title: String, answers: Bool = false, hotkey: Hotkey? = nil) -> BubbleItem {
        BubbleItem(id: UUID(), title: title, symbol: answers ? SelectionBubbleItems.answerSymbol : SelectionBubbleItems.writingSymbol,
                   answers: answers, hotkey: hotkey)
    }

    private func measured(_ items: [BubbleItem], expanded: Bool = true) -> CGSize {
        let view = SelectionBubbleView(visible: Array(items.prefix(3)), more: Array(items.dropFirst(3)), expanded: expanded,
                                       pointer: BubblePointer(), select: { _ in }, expand: {})
        return NSHostingView(rootView: view).fittingSize
    }

    func testTheListIsAsTallAsItsRowsUpToTheRoomBesideTheSelection() {
        let natural = CGSize(width: 200, height: 300)
        XCTAssertEqual(SelectionBubbleController.listSize(natural: natural, room: 600), CGSize(width: 248, height: 300))
        XCTAssertEqual(SelectionBubbleController.listSize(natural: natural, room: 220).height, 220, "scrolls within the room")
        XCTAssertEqual(SelectionBubbleController.listSize(natural: CGSize(width: 260, height: 900), room: 2_000),
                       CGSize(width: 260, height: SelectionBubbleController.listMaxHeight))
        XCTAssertEqual(SelectionBubbleController.listSize(natural: natural, room: 40).height, SelectionBubbleController.listMinHeight,
                       "a few rows at least, even on a tiny display")
        XCTAssertEqual(SelectionBubbleController.listSize(natural: CGSize(width: 900, height: 100), room: 600).width, 320)
    }

    func testThePointerIsCountedFromTheBubblesTopLeft() {
        let frame = CGRect(x: 400, y: 300, width: 248, height: 200)
        XCTAssertEqual(SelectionBubbleController.location(of: CGPoint(x: 410, y: 490), in: frame), CGPoint(x: 10, y: 10))
        XCTAssertNil(SelectionBubbleController.location(of: CGPoint(x: 399, y: 490), in: frame))
        // After the bubble grew downwards, the same point on screen lies further from its top.
        let grown = CGRect(x: 400, y: 100, width: 248, height: 400)
        XCTAssertEqual(SelectionBubbleController.location(of: CGPoint(x: 410, y: 490), in: grown), CGPoint(x: 10, y: 10))
        XCTAssertEqual(SelectionBubbleController.location(of: CGPoint(x: 410, y: 290), in: grown), CGPoint(x: 10, y: 210))
    }

    func testTheListFitsItsLongestRowWithinItsWidths() {
        let short = measured([item("Explain", answers: true), item("Define", answers: true), item("Proofread"), item("Shorten")])
        XCTAssertLessThan(short.width, SelectionBubbleView.listWidths.lowerBound)
        XCTAssertEqual(SelectionBubbleController.listSize(natural: short, room: 800).width, SelectionBubbleView.listWidths.lowerBound)
        let long = measured([item("Explain", answers: true), item("Rewrite this as a friendly but firm reply to a customer"),
                             item("Proofread", hotkey: Hotkey(keyCode: 8, modifiers: 4096 | 512)), item("Shorten")])
        XCTAssertGreaterThan(long.width, SelectionBubbleView.listWidths.upperBound)
        XCTAssertEqual(SelectionBubbleController.listSize(natural: long, room: 800).width, SelectionBubbleView.listWidths.upperBound)
    }

    func testEveryRowAddsOneRowHeight() {
        let few = measured((1...4).map { item("Writing \($0)") })
        let many = measured((1...30).map { item("Writing \($0)") })
        XCTAssertEqual(many.height - few.height, 26 * (SelectionBubbleView.rowHeight + 1), accuracy: 0.5)
        XCTAssertGreaterThan(many.height, SelectionBubbleController.listMaxHeight, "so a long list scrolls")
    }

    func testTheExplainPageSaysWhatEachRuleDoesFromTheBubble() {
        var proofread = Rule(name: "Proofread")
        proofread.hotkey = Hotkey(keyCode: 8, modifiers: 4096 | 512)
        XCTAssertEqual(ExplainView.bubbleRuleDetail(proofread), "Replace selection, in text fields · ⌃⇧C")
        XCTAssertEqual(ExplainView.bubbleRuleDetail(Rule.explainPreset), "Answer")
    }
}
