import XCTest
@testable import FrogCore

final class RuleCopyTests: XCTestCase {
    func testCopyIsANewRuleWithoutTheOriginalsShortcut() {
        var rule = Rule(name: "Proofread", instructions: "Fix it.", model: "small", targetLanguage: "German", hotkey: Hotkey(keyCode: 8, modifiers: 4096 | 512), preset: true)
        rule.action = RuleAction(category: .text)
        rule.action?.localTextModelID = "local"
        let copy = rule.copy()
        XCTAssertNotEqual(copy.id, rule.id)
        XCTAssertEqual(copy.name, "Proofread copy")
        XCTAssertNil(copy.hotkey)
        XCTAssertFalse(copy.preset)
        XCTAssertEqual(copy.instructions, rule.instructions)
        XCTAssertEqual(copy.action, rule.action)
        XCTAssertEqual(copy.model, rule.model)
        XCTAssertEqual(copy.targetLanguage, rule.targetLanguage)
        XCTAssertEqual(copy.enabled, rule.enabled)
    }
}
