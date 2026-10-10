import XCTest
@testable import FrogCore

final class ToolkitTests: XCTestCase {
    func testFeatureMigrationPreservesLegacyEnablementAndBindings() throws {
        var config = Configuration()
        config.preferences.applicationShortcutsEnabled = false
        config.preferences.workflows = WorkflowPreferences()
        config.preferences.workflows?.clipboardHistoryEnabled = true
        config.preferences.workflows?.clipboardHistoryHotkey = Hotkey(keyCode: 9, modifiers: 4096 | 2048)
        let original = try JSONEncoder().encode(config)
        var restored = try JSONDecoder().decode(Configuration.self, from: original)
        XCTAssertFalse(restored.preferences.featureEnabled(.windowSwitcher))
        XCTAssertTrue(restored.preferences.featureEnabled(.clipboard))
        XCTAssertFalse(restored.preferences.featureEnabled(.usage))
        restored.preferences.setFeature(.commandBar, enabled: true)
        XCTAssertFalse(restored.preferences.featureEnabled(.windowSwitcher))
        XCTAssertEqual(restored.rules, config.rules)
        XCTAssertEqual(restored.preferences.workflowSettings.clipboardHistoryHotkey, config.preferences.workflowSettings.clipboardHistoryHotkey)
        restored.preferences.setFeature(.windowSwitcher, enabled: true)
        XCTAssertTrue(restored.preferences.featureEnabled(.windowSwitcher))
        XCTAssertFalse(restored.preferences.featureEnabled(.applicationShortcuts))
    }
    func testDisabledFeatureKeepsOptionsAcrossExportAndRestore() throws {
        var config = Configuration()
        config.preferences.setFeature(.commandBar, enabled: true)
        config.preferences.toolkit?.commandBarHotkey = Hotkey(keyCode: 49, modifiers: 4096)
        config.preferences.setFeature(.commandBar, enabled: false)
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertFalse(restored.preferences.sidebarFeatures.contains(.commandBar))
        XCTAssertEqual(restored.preferences.toolkitSettings.effectiveCommandBarHotkey.modifiers, 4096)
    }
    func testSearchRanksTitlesAndPreservesStableTies() {
        let source = [SearchRecord(id: "1", title: "My notes", keywords: "café"), SearchRecord(id: "2", title: "Café"), SearchRecord(id: "3", title: "Cafe menu")]
        XCTAssertEqual(CommandSearch.results(source, query: "cafe").map(\.id), ["2", "3", "1"])
        XCTAssertEqual(CommandSearch.results(source, query: "menu cafe").map(\.id), ["3"])
        XCTAssertEqual(CommandSearch.results(source, query: "", limit: 1).map(\.id), ["1"])
    }
    func testCalculatorBoundsAndUnitDimensions() {
        XCTAssertEqual(QuickCalculation.result("(2 + 3) * 4"), "20")
        XCTAssertEqual(QuickCalculation.result("2^3^2"), "512")
        XCTAssertEqual(QuickCalculation.result("-2^2"), "-4")
        XCTAssertEqual(QuickCalculation.result("2^-2"), "0.25")
        XCTAssertEqual(QuickCalculation.result("25% * 200"), "50")
        XCTAssertEqual(QuickCalculation.result("1 mi to km"), "1.609344 km")
        XCTAssertEqual(QuickCalculation.result("0 c to f"), "32 f")
        for invalid in ["1/0", "1 +", "1 kg to km", "system('whoami')", String(repeating: "(", count: 1000)] { XCTAssertNil(QuickCalculation.result(invalid)) }
    }
}
