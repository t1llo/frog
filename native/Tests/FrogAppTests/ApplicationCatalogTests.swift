import XCTest
import FrogCore
@testable import FrogApp

final class ApplicationCatalogTests: XCTestCase {
    @MainActor
    func testTabLoadsShareDiscoveryAndRowsUpdateAfterAssigningAShortcut() async {
        var alpha = Rule(name: "Alpha", instructions: "", enabled: false)
        alpha.action = RuleAction(category: .application); alpha.action?.applicationPath = "/Applications/Alpha.app"
        var zulu = Rule(name: "Zulu", instructions: "", enabled: false)
        zulu.action = RuleAction(category: .application); zulu.action?.applicationPath = "/Applications/Zulu.app"
        let discovery = CatalogDiscovery([alpha, zulu])
        let store = ApplicationCatalogStore(discover: { await discovery.scan() })
        async let first: Void = store.loadIfNeeded()
        async let second: Void = store.loadIfNeeded()
        _ = await (first, second)
        await store.loadIfNeeded()
        let scans = await discovery.calls
        XCTAssertEqual(scans, 1)
        XCTAssertEqual(store.rows(configured: []).map(\.name), ["Alpha", "Zulu"])
        zulu.hotkey = Hotkey(keyCode: 0, modifiers: 4096 | 512)
        let updated = store.rows(configured: [zulu])
        XCTAssertEqual(updated.map(\.name), ["Zulu", "Alpha"])
        XCTAssertEqual(updated.first?.hotkey, zulu.hotkey)
        XCTAssertEqual(updated.first?.id, zulu.id)
    }
    func testAssignedShortcutsComeFirstEvenWhenDisabled() {
        func app(_ name: String, assigned: Bool = false) -> Rule {
            var rule = Rule(name: name, instructions: "", enabled: false)
            rule.action = RuleAction(category: .application)
            rule.action?.applicationPath = "/Applications/\(name).app"
            if assigned { rule.hotkey = Hotkey(keyCode: 0, modifiers: 4096 | 512) }
            return rule
        }
        let installed = [app("Alpha"), app("Bravo"), app("Zulu")]
        let configured = [app("Zulu", assigned: true), app("Bravo")]
        let rows = ApplicationCatalog.rows(installed: installed, configured: configured)
        XCTAssertEqual(rows.map(\.name), ["Zulu", "Alpha", "Bravo"])
        XCTAssertFalse(rows[0].enabled)
    }
    func testDiscoveryIncludesUtilitiesSkipsNestedHelpersAndPreservesConfiguredShortcuts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Editor.app", "Utilities/Tool.app", "Editor.app/Contents/Helper.app"] {
            let contents = root.appendingPathComponent(name).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "test.\(UUID().uuidString)", "CFBundleName": URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        }
        let installed = ApplicationCatalog.scan(roots: [root, root])
        XCTAssertEqual(installed.map(\.name), ["Editor", "Tool"])
        XCTAssertTrue(installed.allSatisfy { !$0.enabled && $0.hotkey == nil && $0.category == .application })
        var configuration = Configuration(); configuration.rules = installed
        XCTAssertNoThrow(try ConfigurationFile.validate(configuration))
        var configured = try XCTUnwrap(installed.first)
        configured.hotkey = Hotkey(keyCode: 0, modifiers: 4096 | 512); configured.enabled = true
        let rows = ApplicationCatalog.rows(installed: installed, configured: [configured])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first, configured)
    }
}

private actor CatalogDiscovery {
    let applications: [Rule]
    var calls = 0
    init(_ applications: [Rule]) { self.applications = applications }
    func scan() -> [Rule] { calls += 1; return applications }
}
