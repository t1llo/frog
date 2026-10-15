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
        XCTAssertEqual(items(rules).visible.last?.symbol, "pencil.line")
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
}
