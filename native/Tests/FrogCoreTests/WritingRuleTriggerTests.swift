import XCTest
@testable import FrogCore

final class WritingRuleTriggerTests: XCTestCase {
    func testOnlyFrogsOwnAnswerRuleBelongsToExplain() {
        var preferences = Preferences()
        preferences.setFeature(.writing, enabled: true)
        preferences.setFeature(.explain, enabled: false)
        var summarize = Rule(name: "Summarize")
        summarize.action = RuleAction(category: .text)
        summarize.action?.textOutput = .panel
        XCTAssertTrue(Rule.explainPreset.isExplainRule)
        XCTAssertFalse(summarize.isExplainRule, "a rule the person made is a Writing rule that shows its result")
        XCTAssertTrue(summarize.isWritingRule)
        XCTAssertFalse(preferences.ruleFeatureEnabled(Rule.explainPreset))
        XCTAssertTrue(preferences.ruleFeatureEnabled(summarize))
    }

    func testTriggersAreOnUntilTurnedOffAndOldFilesStillRead() throws {
        var rule = Rule(name: "Proofread")
        XCTAssertTrue(rule.showsInBubble)
        XCTAssertTrue(rule.showsInCommandBar)
        XCTAssertEqual(rule.textOutput, .replace)
        rule.showsInBubble = false
        rule.showsInCommandBar = false
        rule.action?.textOutput = .copy
        let decoded = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule))
        XCTAssertFalse(decoded.showsInBubble)
        XCTAssertFalse(decoded.showsInCommandBar)
        XCTAssertEqual(decoded.textOutput, .copy)
        // Turning a trigger back on leaves no trace in the file.
        rule.showsInBubble = true
        XCTAssertNil(rule.action?.bubble)
        XCTAssertEqual(TextOutput.allCases.map(\.title), ["Replace", "Copy", "Show"])
    }

    func testBubbleOffersCopyRulesOutsideTextFields() {
        var copy = Rule(name: "Translate")
        copy.action = RuleAction(category: .text)
        copy.action?.textOutput = .copy
        var hidden = Rule(name: "Hidden")
        hidden.showsInBubble = false
        let rules = [Rule(name: "Proofread"), copy, hidden, Rule.explainPreset]
        let read = SelectionBubbleItems.items(rules: rules, explainEnabled: true, writingEnabled: true, editable: false,
                                              configured: { _ in true })
        XCTAssertEqual(read.visible.map(\.title), ["Explain", "Translate"])
        let field = SelectionBubbleItems.items(rules: rules, explainEnabled: false, writingEnabled: true, editable: true,
                                               configured: { _ in true })
        XCTAssertEqual(field.visible.map(\.title), ["Proofread", "Translate"])
    }
}
