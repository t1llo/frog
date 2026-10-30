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

    func testTheExplainRuleStaysExplainsWhenItsModelGoes() {
        var config = Configuration()
        config.rules = []
        config.adoptExplainPreset(installed: [])
        let provider = UUID()
        config.rules[0].providerID = provider; config.rules[0].model = "gone"
        config.modelsRemoved([RuleModelSelection(providerID: provider, modelID: "gone", category: .text)], installed: [])
        XCTAssertFalse(config.rules[0].preset, "a model change clears preset")
        XCTAssertTrue(config.rules[0].isExplainRule)
        XCTAssertFalse(config.rules[0].isWritingRule)
        XCTAssertFalse(config.rules[0].copy().isExplainRule, "a copy is the person's own answer rule")
    }

    func testRulesFromBeforeTheOwnerFlagFindTheirExplainRuleOnce() throws {
        func older(_ rules: [Rule]) throws -> Configuration {
            var config = Configuration()
            config.rules = rules.map { var rule = $0; rule.action?.explain = nil; return rule }
            var workflow = WorkflowPreferences(); workflow.explainPresetVersion = 2
            config.preferences.workflows = workflow
            return config
        }
        // The preset rule, as version 2 left it.
        var config = try older([Rule(name: "Proofread"), Rule.explainPreset])
        XCTAssertFalse(config.rules[1].isExplainRule)
        config.adoptExplainPreset(installed: [])
        XCTAssertTrue(config.rules[1].isExplainRule)
        XCTAssertEqual(config.rules.count, 2)

        // A provider deleted earlier cleared preset; the answer rule called Explain is still the one.
        var unmarked = Rule.explainPreset; unmarked.preset = false
        var define = Rule.explainPreset; define.id = UUID(); define.name = "Define"; define.preset = false
        config = try older([define, unmarked])
        config.adoptExplainPreset(installed: [])
        XCTAssertEqual(config.rules.filter(\.isExplainRule).map(\.id), [unmarked.id])
        XCTAssertEqual(config.preferences.workflowSettings.explainPresetVersion, Rule.explainPresetVersion)

        // Adopted once: deleting it later does not make Define Explain's.
        config.rules.removeAll { $0.id == unmarked.id }
        config.adoptExplainPreset(installed: [])
        XCTAssertFalse(config.rules.contains(where: \.isExplainRule))
    }
}
