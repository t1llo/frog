import XCTest
@testable import FrogCore

final class ShortcutReferenceTests: XCTestCase {
    private let key = Hotkey(keyCode: 1, modifiers: 4096 | 512)

    private func rule(_ name: String, _ category: RuleCategory, hotkey: Hotkey? = Hotkey(keyCode: 2, modifiers: 4096 | 512), enabled: Bool = true) -> Rule {
        var rule = Rule(name: name, hotkey: hotkey, enabled: enabled)
        rule.action = RuleAction(category: category)
        return rule
    }

    private func configuration(_ rules: [Rule]) -> Configuration {
        var configuration = Configuration()
        configuration.rules = rules
        return configuration
    }

    func testRulesLandOnTheirPageAndAnswerRulesUnderExplain() {
        let fix = rule("Fix", .text), ask = rule("Ask", .text), dictate = rule("Dictate", .audio), left = rule("Left half", .window)
        var extra = Rule(name: "Next display", hotkey: key)
        extra.action = RuleAction(category: .window)
        let items = ShortcutReference.items(configuration: configuration([fix, ask, dictate, left]), ruleEnabled: { _ in true },
                                           extraRules: [extra], answersInPanel: { $0.id == ask.id })
        let group = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.group) })
        XCTAssertEqual(group[fix.id.uuidString], .writing)
        XCTAssertEqual(group[ask.id.uuidString], .explain)
        XCTAssertEqual(group[dictate.id.uuidString], .dictation)
        XCTAssertEqual(group[left.id.uuidString], .shortcuts)
        XCTAssertEqual(group[extra.id.uuidString], .shortcuts)
    }

    func testOnlyEnabledRulesWithAShortcutWhosePageIsOnAreListed() {
        let off = rule("Off", .text, enabled: false), bare = rule("Bare", .text, hotkey: nil), audio = rule("Dictate", .audio), text = rule("Fix", .text)
        let items = ShortcutReference.items(configuration: configuration([off, bare, audio, text]), ruleEnabled: { $0.category != .audio })
        let ids = Set(items.map(\.id))
        XCTAssertTrue(ids.contains(text.id.uuidString))
        XCTAssertFalse(ids.contains(off.id.uuidString))
        XCTAssertFalse(ids.contains(bare.id.uuidString))
        XCTAssertFalse(ids.contains(audio.id.uuidString))
    }

    func testFrogShortcutsFollowTheirFeatures() {
        var config = configuration([])
        config.preferences.setFeature(.commandBar, enabled: false)
        config.preferences.setFeature(.clipboard, enabled: false)
        var ids = ShortcutReference.items(configuration: config, ruleEnabled: { _ in true }).map(\.id)
        XCTAssertFalse(ids.contains("frog.command-bar"))
        XCTAssertFalse(ids.contains("frog.clipboard"))
        XCTAssertFalse(ids.contains("frog.shortcuts"), "No Show shortcuts row without its key")

        config.preferences.setFeature(.commandBar, enabled: true)
        config.preferences.setFeature(.clipboard, enabled: true)
        var workflow = config.preferences.workflowSettings
        workflow.shortcutPanelHotkey = key
        config.preferences.workflows = workflow
        ids = ShortcutReference.items(configuration: config, ruleEnabled: { _ in true }).map(\.id)
        XCTAssertEqual(ids.filter { $0.hasPrefix("frog.") }, ["frog.command-bar", "frog.clipboard", "frog.window-switcher", "frog.shortcuts"])
    }

    func testGroupsComeInPageOrderWithoutEmptyOnes() {
        let items = [
            ShortcutReferenceItem(id: "a", title: "A", hotkey: key, group: .frog),
            ShortcutReferenceItem(id: "b", title: "B", hotkey: key, group: .dictation),
            ShortcutReferenceItem(id: "c", title: "C", hotkey: key, group: .writing),
            ShortcutReferenceItem(id: "d", title: "D", hotkey: key, group: .frog)
        ]
        let groups = ShortcutReference.grouped(items)
        XCTAssertEqual(groups.map(\.group), [.writing, .dictation, .frog])
        XCTAssertEqual(groups.last?.items.map(\.id), ["a", "d"])
        XCTAssertTrue(ShortcutReference.grouped([]).isEmpty)
    }

    func testCaptionsArePageNames() {
        for group in ShortcutReferenceGroup.allCases {
            XCTAssertFalse(["Text", "Audio", "Other"].contains(group.title))
        }
    }
}
