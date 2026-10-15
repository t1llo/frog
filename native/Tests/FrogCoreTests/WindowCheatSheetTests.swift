import XCTest
@testable import FrogCore

final class WindowCheatSheetTests: XCTestCase {
    private func rule(_ action: WindowAction, keyCode: UInt32, enabled: Bool = true) -> Rule {
        var rule = action.rule
        rule.hotkey = Hotkey(keyCode: keyCode, modifiers: 4096 | 2048); rule.enabled = enabled
        return rule
    }

    func testEveryLayoutHasAGroupInTheSheetOrder() {
        for action in WindowAction.allCases {
            XCTAssertTrue(WindowCheatSheet.order.contains(WindowCheatSheet.group(for: action)), action.title)
        }
        XCTAssertEqual(WindowCheatSheet.group(for: .leftHalf), "Halves")
        XCTAssertEqual(WindowCheatSheet.group(for: .bottomRight), "Quarters")
        XCTAssertEqual(WindowCheatSheet.group(for: .rightTwoThirds), "Thirds")
        XCTAssertEqual(WindowCheatSheet.group(for: .centeredLarge), "Sizes")
        XCTAssertEqual(WindowCheatSheet.group(for: .previousDisplay), "Displays")
        XCTAssertEqual(WindowCheatSheet.group(for: .restore), "Undo")
    }

    func testSectionsAreGroupedAndOrdered() {
        let key = Hotkey(keyCode: 44, modifiers: 4096 | 2048)
        let rules = [rule(.restore, keyCode: 51), rule(.rightHalf, keyCode: 124), rule(.maximize, keyCode: 36),
                     rule(.leftHalf, keyCode: 123), rule(.nextDisplay, keyCode: 2)]
        let sections = WindowCheatSheet.sections(rules: rules, commands: [(.cheatSheet, key)])
        XCTAssertEqual(sections.map(\.title), ["Halves", "Sizes", "Displays", "Undo", "Windows"])
        XCTAssertEqual(sections[0].items.map(\.title), [WindowAction.leftHalf.title, WindowAction.rightHalf.title])
        XCTAssertEqual(sections[0].items[0].hotkey, Hotkey(keyCode: 123, modifiers: 4096 | 2048))
        XCTAssertEqual(sections[0].items[0].action, .leftHalf)
        XCTAssertEqual(sections.last?.items, [WindowCheatSheet.Item(title: WindowCommand.cheatSheet.title, command: .cheatSheet, hotkey: key)])
    }

    func testDisabledRulesAndRulesWithoutShortcutsAreLeftOut() {
        var text = Rule(name: "Text", instructions: "test", hotkey: Hotkey(keyCode: 0, modifiers: 4096 | 2048))
        text.enabled = true
        let rules = [rule(.leftHalf, keyCode: 123, enabled: false), WindowAction.rightHalf.rule, text, rule(.center, keyCode: 8)]
        let sections = WindowCheatSheet.sections(rules: rules, commands: [])
        XCTAssertEqual(sections.map(\.title), ["Sizes"])
        XCTAssertEqual(sections[0].items.map(\.action), [.center])
        XCTAssertEqual(WindowCheatSheet.sections(rules: [], commands: []), [])
    }
}
