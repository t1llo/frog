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
        let define = answer("Define")
        let rules = [Rule.explainPreset, define, proofread]
        let result = SelectionBubbleItems.items(rules: rules, explainEnabled: true, writingEnabled: true, editable: true,
                                                hidden: [define.id], configured: { _ in true })
        XCTAssertEqual(titles(result.visible), ["Explain", "Proofread"])
        XCTAssertEqual(result.visible.last?.hotkey, proofread.hotkey)
        XCTAssertEqual(SelectionBubbleItems.candidates(rules: rules, explainEnabled: true, writingEnabled: true).map(\.name),
                       ["Explain", "Define", "Proofread"], "The Explain page lists hidden rules too, to show them again")
        XCTAssertEqual(SelectionBubbleItems.candidates(rules: rules, explainEnabled: true, writingEnabled: false).map(\.name),
                       ["Explain", "Define"])
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

    func testExplainOffLeavesOutAnswerRules() {
        let rules = [Rule.explainPreset, answer("Define"), writing("Proofread")]
        XCTAssertEqual(titles(items(rules, explain: false).visible), ["Proofread"])
        XCTAssertTrue(items(rules, explain: false, editable: false).visible.isEmpty)
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
        XCTAssertEqual(titles(result.visible), ["Explain", "Answer 1", "Answer 2"])
        XCTAssertEqual(titles(result.more), (3...6).map { "Answer \($0)" } + (1...20).map { "Writing \($0)" })
        XCTAssertEqual(result.more.filter(\.answers).count, 4, "answer rules stay together ahead of Writing rules")
    }

    func testHidingEveryRuleLeavesNothingToShow() {
        let rules = [Rule.explainPreset, answer("Define"), writing("Proofread")]
        let result = SelectionBubbleItems.items(rules: rules, explainEnabled: true, writingEnabled: true, editable: true,
                                                hidden: Set(rules.map(\.id)), configured: { _ in true })
        XCTAssertTrue(result.visible.isEmpty)
        XCTAssertTrue(result.more.isEmpty)
    }

    func testARuleHiddenOrMissingDoesNotTakeASlotInTheBar() {
        let rules = [Rule.explainPreset, answer("Define"), answer("Summarize"), writing("Proofread"), writing("Shorten")]
        let gone = UUID()
        let result = SelectionBubbleItems.items(rules: rules, explainEnabled: true, writingEnabled: true, editable: true,
                                                hidden: [rules[1].id, gone], configured: { _ in true })
        XCTAssertEqual(titles(result.visible), ["Explain", "Summarize", "Proofread", "Shorten"], "four fit without More")
        XCTAssertTrue(result.more.isEmpty)
    }
}
