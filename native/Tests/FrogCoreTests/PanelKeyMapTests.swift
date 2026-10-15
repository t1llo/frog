import XCTest
@testable import FrogCore

final class PanelKeyMapTests: XCTestCase {
    private let idle = PanelState(queryIsEmpty: true, actionPanelOpen: false, clearsQueryOnEscape: true)

    func testEveryKeyInTheTable() {
        let rows: [(UInt16, PanelModifiers, PanelCommand)] = [
            (36, [], .runPrimary), (76, [], .runPrimary),
            (36, .command, .runSecondary), (76, .command, .runSecondary),
            (36, .shift, .runPlain),
            (36, [.command, .shift], .pass),
            (36, .option, .pass),
            (40, .command, .toggleActions), (40, [], .pass),
            (125, [], .moveDown), (45, .control, .moveDown), (45, [], .pass),
            (126, [], .moveUp), (35, .control, .moveUp), (35, [], .pass),
            (13, .command, .close), (13, [], .pass),
            (53, [], .close),
            (0, [], .pass), (49, [], .pass), (8, .command, .pass)
        ]
        for (code, modifiers, expected) in rows {
            XCTAssertEqual(PanelKeyMap.decide(keyCode: code, modifiers: modifiers, state: idle), expected, "key \(code) \(modifiers.rawValue)")
        }
    }

    func testEscapeClosesActionsThenClearsTheQueryThenClosesThePanel() {
        var state = PanelState(queryIsEmpty: false, actionPanelOpen: true, clearsQueryOnEscape: true)
        XCTAssertEqual(PanelKeyMap.decide(keyCode: 53, modifiers: [], state: state), .closeActions)
        state.actionPanelOpen = false
        XCTAssertEqual(PanelKeyMap.decide(keyCode: 53, modifiers: [], state: state), .clearQuery)
        state.queryIsEmpty = true
        XCTAssertEqual(PanelKeyMap.decide(keyCode: 53, modifiers: [], state: state), .close)
        // A panel that does not clear on Escape closes even with a query.
        state = PanelState(queryIsEmpty: false, actionPanelOpen: false, clearsQueryOnEscape: false)
        XCTAssertEqual(PanelKeyMap.decide(keyCode: 53, modifiers: [], state: state), .close)
    }

    func testCommandDigitsRunActionsOnlyWhileTheActionPanelIsOpen() {
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let open = PanelState(actionPanelOpen: true)
        for (index, code) in digits.enumerated() {
            XCTAssertEqual(PanelKeyMap.decide(keyCode: code, modifiers: .command, state: open), .runAction(index))
            XCTAssertEqual(PanelKeyMap.decide(keyCode: code, modifiers: .command, state: idle), .pass)
            XCTAssertEqual(PanelKeyMap.decide(keyCode: code, modifiers: [], state: open), .pass)
        }
        XCTAssertEqual(PanelKeyMap.decide(keyCode: 29, modifiers: .command, state: open), .pass)  // ⌘0
    }

    func testAnInputMethodComposingGetsEveryKey() {
        let composing = PanelState(queryIsEmpty: false, actionPanelOpen: true, clearsQueryOnEscape: true, composing: true)
        for (code, modifiers) in [(36, []), (53, []), (125, []), (126, []), (40, .command), (18, .command)] as [(UInt16, PanelModifiers)] {
            XCTAssertEqual(PanelKeyMap.decide(keyCode: code, modifiers: modifiers, state: composing), .pass)
        }
    }
}
