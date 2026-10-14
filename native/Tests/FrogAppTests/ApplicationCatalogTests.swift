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
        let store = ApplicationCatalogStore(discover: { ApplicationCatalog.Discovery(rules: await discovery.scan(), alternativeNames: ["/Applications/Zulu.app": ["Zed"]]) })
        async let first: Void = store.loadIfNeeded()
        async let second: Void = store.loadIfNeeded()
        _ = await (first, second)
        await store.loadIfNeeded()
        let scans = await discovery.calls
        XCTAssertEqual(scans, 1)
        XCTAssertEqual(store.rows(configured: []).map(\.name), ["Alpha", "Zulu"])
        XCTAssertEqual(store.alternativeNames, ["/Applications/Zulu.app": ["Zed"]])
        zulu.hotkey = Hotkey(keyCode: 0, modifiers: 4096 | 512)
        let updated = store.rows(configured: [zulu])
        XCTAssertEqual(updated.map(\.name), ["Zulu", "Alpha"])
        XCTAssertEqual(updated.first?.hotkey, zulu.hotkey)
        XCTAssertEqual(updated.first?.id, zulu.id)
    }
    @MainActor
    func testEveryCallerThatWaitedForAScanFindsItsApplications() async {
        var alpha = Rule(name: "Alpha", instructions: "", enabled: false)
        alpha.action = RuleAction(category: .application); alpha.action?.applicationPath = "/Applications/Alpha.app"
        let gate = CatalogGate([alpha])
        let store = ApplicationCatalogStore(discover: { ApplicationCatalog.Discovery(rules: await gate.scan()) })
        // The command bar reads the list as soon as its wait ends. One that joined a scan already under way must
        // not be let through before the scan's result is stored.
        var joined = 0
        let first = Task { @MainActor in await store.loadIfNeeded(); return store.installed.map(\.name) }
        await gate.started()
        let late = (0..<3).map { _ in
            Task { @MainActor in joined += 1; return await store.load().map(\.name) }
        }
        while joined < late.count { await Task.yield() }
        XCTAssertEqual(store.installed, [])
        await gate.release()
        for caller in late {
            let found = await caller.value
            XCTAssertEqual(found, ["Alpha"])
        }
        let found = await first.value
        XCTAssertEqual(found, ["Alpha"])
        let scans = await gate.calls
        XCTAssertEqual(scans, 1)
    }
    func testFinderLinkedIntoAnApplicationsFolderIsListedOnce() throws {
        let finder = "/System/Library/CoreServices/Finder.app"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Finder.app"), withDestinationURL: URL(fileURLWithPath: finder))
        // Finder is added by its own path when the system folder is scanned, and the link resolves to that path.
        let found = ApplicationCatalog.scan(roots: [root, URL(fileURLWithPath: "/System/Applications", isDirectory: true)]).rules
        XCTAssertEqual(found.filter { $0.action?.applicationPath == finder }.map(\.name), ["Finder"])
        XCTAssertEqual(Set(found.compactMap { $0.action?.applicationPath }).count, found.count)
    }
    @MainActor
    func testARescanKeepsIdentifiersAndSurvivesAnApplicationFoundTwice() async {
        // Every scan builds its rules anew. The same path twice is what a scan with a linked Finder used to return.
        let store = ApplicationCatalogStore(rescanAfter: .zero, discover: {
            ApplicationCatalog.Discovery(rules: [("Alpha", "/Applications/Alpha.app"), ("Finder", "/fixture/Finder.app"), ("Finder", "/fixture/Finder.app")].map { name, path in
                var rule = Rule(name: name, instructions: "", enabled: false)
                rule.action = RuleAction(category: .application); rule.action?.applicationPath = path
                return rule
            })
        })
        let first = await store.load()
        let second = await store.load()
        XCTAssertEqual(first.map(\.name), ["Alpha", "Finder", "Finder"])
        XCTAssertEqual(second.first?.id, first.first?.id)
        XCTAssertEqual(second.map(\.name), first.map(\.name))
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
        let installed = ApplicationCatalog.scan(roots: [root, root], displayName: finderName).rules
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
    func testDiscoveryStopsThreeFoldersBelowAnApplicationsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Suite/Top.app", "Suite/Catalogue/Plants/Nested.app", "Suite/Catalogue/Plants/Support/Deep.app", "Suite/Catalogue/Plants/Support/More/Deeper.app"] {
            let contents = root.appendingPathComponent(name).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "test.\(UUID().uuidString)", "CFBundleName": URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        }
        XCTAssertEqual(ApplicationCatalog.scan(roots: [root], displayName: finderName).rules.map(\.name), ["Nested", "Top"])
    }
    func testApplicationsCarryTheNameFinderShowsAndKeepTheirBundleNamesForSearch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (file, name, displayName) in [("Visual Studio Fixture.app", "Code", "Code"), ("FixtureVPN.app", "FixtureVPN", "Fixture VPN"), ("Plain.app", "Plain", nil)] {
            let contents = root.appendingPathComponent(file).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "test.\(UUID().uuidString)", "CFBundleName": name, "CFBundlePackageType": "APPL"]
            info["CFBundleDisplayName"] = displayName
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        }
        let found = ApplicationCatalog.scan(roots: [root], displayName: finderName)
        XCTAssertEqual(found.rules.map(\.name), ["FixtureVPN", "Plain", "Visual Studio Fixture"])
        let names = Dictionary(uniqueKeysWithValues: found.rules.map { ($0.name, found.alternativeNames[$0.action?.applicationPath ?? ""]) })
        XCTAssertEqual(names, ["FixtureVPN": ["Fixture VPN"], "Plain": nil, "Visual Studio Fixture": ["Code"]])
    }
}

/// The name Finder shows for a fixture when it shows every extension. Asking the system for it would register the
/// fixture with Launch Services, where it outlives the test.
private func finderName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

/// A scan that waits to be let through, so that callers can arrive while it runs.
private actor CatalogGate {
    let applications: [Rule]
    var calls = 0
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(_ applications: [Rule]) { self.applications = applications }
    func scan() async -> [Rule] {
        calls += 1
        for waiter in waiting { waiter.resume() }; waiting = []
        if !open { await withCheckedContinuation { waiting.append($0) } }
        return applications
    }
    func started() async {
        if calls == 0 { await withCheckedContinuation { waiting.append($0) } }
    }
    func release() { open = true; for waiter in waiting { waiter.resume() }; waiting = [] }
}

private actor CatalogDiscovery {
    let applications: [Rule]
    var calls = 0
    init(_ applications: [Rule]) { self.applications = applications }
    func scan() -> [Rule] { calls += 1; return applications }
}
