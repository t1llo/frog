import XCTest
@testable import FrogCore

final class SelectionBubbleItemsTests: XCTestCase {
    private func answer(_ name: String, enabled: Bool = true) -> Rule {
        var rule = Rule(name: name, enabled: enabled)
        rule.action = RuleAction(category: .text)
        rule.action?.textOutput = .panel
        return rule
    }

    private func writing(_ name: String, enabled: Bool = true) -> Rule { Rule(name: name, enabled: enabled) }

    private func titles(_ items: [BubbleItem]) -> [String] { items.map(\.title) }

    private func items(_ rules: [Rule], explain: Bool = true, writing: Bool = true, editable: Bool = true,
                       configured: (Rule) -> Bool = { _ in true }) -> (visible: [BubbleItem], more: [BubbleItem]) {
        SelectionBubbleItems.items(rules: rules, explainEnabled: explain, writingEnabled: writing, editable: editable,
                                   configured: configured)
    }

    func testExplainLeadsTheAnswerRules() {
        let rules = [answer("Summarize"), writing("Proofread"), Rule.explainPreset, answer("Define")]
        let result = items(rules, editable: false)
        XCTAssertEqual(titles(result.visible), ["Explain", "Summarize", "Define"])
        XCTAssertTrue(result.more.isEmpty)
        XCTAssertEqual(result.visible.first?.id, rules[2].id)
        XCTAssertEqual(result.visible.first?.symbol, "questionmark.bubble")
        XCTAssertEqual(result.visible.map(\.answers), [true, true, true])
        XCTAssertEqual(titles(items([answer("Define"), answer("Explain")]).visible), ["Define", "Explain"],
                       "a custom rule named Explain keeps its place")
    }

    func testHiddenRulesStayOutAndShortcutsComeAlong() {
        var proofread = writing("Proofread")
        proofread.hotkey = Hotkey(keyCode: 8, modifiers: 4096 | 512)
        var define = answer("Define")
        define.showsInBubble = false
        let rules = [Rule.explainPreset, define, proofread]
        let result = items(rules)
        XCTAssertEqual(titles(result.visible), ["Explain", "Proofread"])
        XCTAssertEqual(result.visible.last?.hotkey, proofread.hotkey)
        XCTAssertEqual(SelectionBubbleItems.candidates(rules: rules, explainEnabled: true, writingEnabled: true).map(\.name),
                       ["Explain", "Define", "Proofread"], "The Writing page lists hidden rules too, to show them again")
        XCTAssertEqual(SelectionBubbleItems.candidates(rules: rules, explainEnabled: true, writingEnabled: false).map(\.name),
                       ["Explain"])
    }

    func testDisabledAndUnconfiguredRulesAreLeftOut() {
        let rules = [Rule.explainPreset, answer("Off", enabled: false), answer("No model"), writing("Paused", enabled: false),
                     writing("Proofread")]
        let result = items(rules, configured: { $0.name != "No model" })
        XCTAssertEqual(titles(result.visible), ["Explain", "Proofread"])
    }

    func testWritingRulesOnlyInEditableFieldsWithWritingOn() {
        var dictation = Rule.dictationPreset
        dictation.enabled = true
        let rules = [writing("Proofread"), Rule.explainPreset, dictation]
        XCTAssertEqual(titles(items(rules).visible), ["Explain", "Proofread"], "only text rules")
        XCTAssertEqual(items(rules).visible.last?.symbol, SelectionBubbleItems.writingSymbol)
        XCTAssertEqual(items(rules).visible.last?.answers, false)
        XCTAssertEqual(titles(items(rules, editable: false).visible), ["Explain"])
        XCTAssertEqual(titles(items(rules, writing: false).visible), ["Explain"])
    }

    func testExplainOffLeavesOutTheExplainRule() {
        let rules = [Rule.explainPreset, answer("Define"), writing("Proofread")]
        XCTAssertEqual(titles(items(rules, explain: false).visible), ["Define", "Proofread"])
        XCTAssertEqual(titles(items(rules, explain: false, editable: false).visible), ["Define"])
    }

    func testMoreThanFourItemsKeepThreeVisible() {
        let four = [Rule.explainPreset, answer("Define"), writing("Proofread"), writing("Shorten")]
        XCTAssertEqual(items(four).visible.count, 4)
        XCTAssertTrue(items(four).more.isEmpty)
        let result = items(four + [writing("Translate")])
        XCTAssertEqual(titles(result.visible), ["Explain", "Define", "Proofread"])
        XCTAssertEqual(titles(result.more), ["Shorten", "Translate"])
    }

    func testExplainLeadsUnderANewName() {
        var explain = Rule.explainPreset
        explain.name = "Erklären"
        let result = items([answer("Define"), writing("Proofread"), explain])
        XCTAssertEqual(titles(result.visible), ["Erklären", "Define", "Proofread"])
        XCTAssertEqual(SelectionBubbleItems.candidates(rules: [answer("Define"), explain], explainEnabled: true, writingEnabled: true)
                        .map(\.id).first, explain.id)
    }

    func testTitlesLeaveOutSurroundingSpaceAndLineBreaks() {
        XCTAssertEqual(titles(items([writing("  Proofread\n")]).visible), ["Proofread"])
    }

    func testManyRulesKeepTheirOrderBehindMore() {
        let answers = (1...6).map { answer("Answer \($0)") }
        let writings = (1...20).map { writing("Writing \($0)") }
        let result = items(writings + [Rule.explainPreset] + answers)
        XCTAssertEqual(titles(result.visible), ["Explain", "Writing 1", "Writing 2"])
        XCTAssertEqual(titles(result.more), (3...20).map { "Writing \($0)" } + (1...6).map { "Answer \($0)" },
                       "the person's own rules keep their order, whatever they do with the result")
    }

    func testHidingEveryRuleLeavesNothingToShow() {
        let rules = [Rule.explainPreset, answer("Define"), writing("Proofread")].map { rule -> Rule in
            var hidden = rule; hidden.showsInBubble = false; return hidden
        }
        let result = items(rules)
        XCTAssertTrue(result.visible.isEmpty)
        XCTAssertTrue(result.more.isEmpty)
    }

    func testARuleHiddenDoesNotTakeASlotInTheBar() {
        var rules = [Rule.explainPreset, answer("Define"), answer("Summarize"), writing("Proofread"), writing("Shorten")]
        rules[1].showsInBubble = false
        let result = items(rules)
        XCTAssertEqual(titles(result.visible), ["Explain", "Summarize", "Proofread", "Shorten"], "four fit without More")
        XCTAssertTrue(result.more.isEmpty)
    }
}
