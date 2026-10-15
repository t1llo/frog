import XCTest
@testable import FrogCore

final class AppIdentityTests: XCTestCase {
    private struct FakeSignatures: CodeSignatureReading {
        var byLastComponent: [String: CodeSignatureInfo]
        func signature(of bundle: URL) -> CodeSignatureInfo? { byLastComponent[bundle.lastPathComponent] }
    }

    private let inspector = AppBundleInspector(owner: { _ in .user })

    func testInspectorReadsNamesVersionAndNestedBundlesButSkipsFrameworksAndApple() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let bundle = try fixture.app("Slack", bundleID: "com.tinyspeck.slackmacgap", version: "4.41", nested: [
            (file: "Frameworks/Slack Helper.app", bundleID: "com.tinyspeck.slackmacgap.helper"),
            (file: "Frameworks/Electron Framework.framework/Helpers/Inner.app", bundleID: "com.example.inner"),
            (file: "PlugIns/Share.appex", bundleID: "com.tinyspeck.slackmacgap.share"),
            (file: "XPCServices/Fetch.xpc", bundleID: "com.tinyspeck.slackmacgap.fetch"),
            (file: "XPCServices/Duplicate.xpc", bundleID: "com.tinyspeck.slackmacgap.fetch"),
            (file: "XPCServices/Installer.xpc", bundleID: "org.sparkle-project.InstallerLauncher"),
            (file: "PlugIns/Apple.appex", bundleID: "com.apple.share.extension")
        ])
        let identity = try inspector.identity(of: bundle)
        XCTAssertEqual(identity.path, bundle.standardizedFileURL.path)
        XCTAssertEqual(identity.name, "Slack")
        XCTAssertEqual(identity.bundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(identity.bundleName, "Slack")
        XCTAssertEqual(identity.executableName, "Slack")
        XCTAssertEqual(identity.version, "4.41")
        XCTAssertEqual(Set(identity.nestedBundleIDs), ["com.tinyspeck.slackmacgap.helper", "com.tinyspeck.slackmacgap.share",
                                                       "com.tinyspeck.slackmacgap.fetch"])
        XCTAssertEqual(identity.nestedBundleIDs.count, 3)
        XCTAssertEqual(identity.bundleIDs.first, "com.tinyspeck.slackmacgap")
        XCTAssertFalse(identity.isAppleApp)
        XCTAssertEqual(try inspector.identity(of: bundle, displayName: "Slack Chat.app").name, "Slack Chat")
        let calculator = try fixture.app("Calculator", bundleID: "com.apple.calculator")
        XCTAssertTrue(try inspector.identity(of: calculator).isAppleApp)
    }

    func testNestedBundleGroupsAreAddedToTheAppGroups() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let bundle = try fixture.app("Notes Plus", bundleID: "com.example.notesplus", nested: [
            (file: "PlugIns/Widget.appex", bundleID: "com.example.notesplus.widget"),
            (file: "PlugIns/Share.appex", bundleID: "com.example.notesplus.share")
        ])
        let signatures = FakeSignatures(byLastComponent: [
            "Notes Plus.app": CodeSignatureInfo(teamID: "ABCDE12345", appGroups: ["ABCDE12345.com.example.notesplus"]),
            "Widget.appex": CodeSignatureInfo(teamID: "ABCDE12345", appGroups: ["group.com.example.notesplus.widget",
                                                                               "ABCDE12345.com.example.notesplus"])
        ])
        let identity = try AppBundleInspector(signatures: signatures, owner: { _ in .user }).identity(of: bundle)
        XCTAssertEqual(identity.appGroups, ["ABCDE12345.com.example.notesplus", "group.com.example.notesplus.widget"])
    }

    func testNamesDropTrailingVersionsAndDuplicates() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let bundle = try fixture.app("Foo 2", bundleID: "com.example.foo", executable: "Foo", bundleName: "Foo")
        XCTAssertEqual(try inspector.identity(of: bundle).names, ["Foo"])
        let identity = AppIdentity(path: "/Applications/Bar 2024.app", name: "Bar 2024", bundleID: "com.example.bar",
                                   bundleName: "bar", displayName: " ", executableName: "Bar Helper 3.1")
        XCTAssertEqual(identity.names, ["Bar", "Bar Helper"])
        XCTAssertEqual(AppIdentity(path: "/Applications/2048.app", name: "2048", bundleID: "com.example.game").names, ["2048"])
    }

    func testAppStoreReceiptSystemExtensionAndLoginItemsAreNoticed() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let plain = try inspector.identity(of: try fixture.app("Plain", bundleID: "com.example.plain"))
        XCTAssertFalse(plain.isAppStore)
        XCTAssertFalse(plain.hasSystemExtensions)
        XCTAssertFalse(plain.hasLoginItems)
        let full = try inspector.identity(of: try fixture.app("Full", bundleID: "com.example.full", appStore: true,
                                                               systemExtension: true, loginItem: true))
        XCTAssertTrue(full.isAppStore)
        XCTAssertTrue(full.hasSystemExtensions)
        XCTAssertTrue(full.hasLoginItems)
        let agent = try fixture.app("Agent", bundleID: "com.example.agent")
        try FileManager.default.createDirectory(at: agent.appendingPathComponent("Contents/Library/LaunchAgents"), withIntermediateDirectories: true)
        try Data().write(to: agent.appendingPathComponent("Contents/Library/LaunchAgents/com.example.agent.plist"))
        XCTAssertTrue(try inspector.identity(of: agent).hasLoginItems)
    }

    func testSignatureReaderSuppliesTeamAndGroups() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let bundle = try fixture.app("Signed", bundleID: "com.example.signed")
        XCTAssertNil(try inspector.identity(of: bundle).teamID)
        XCTAssertEqual(try inspector.identity(of: bundle).appGroups, [])
        let signatures = FakeSignatures(byLastComponent: [
            "Signed.app": CodeSignatureInfo(teamID: "ABCDE12345", appGroups: ["ABCDE12345.shared", "ABCDE12345.shared"])
        ])
        let identity = try AppBundleInspector(signatures: signatures, owner: { _ in .administrator }).identity(of: bundle)
        XCTAssertEqual(identity.teamID, "ABCDE12345")
        XCTAssertEqual(identity.appGroups, ["ABCDE12345.shared"])
        XCTAssertEqual(identity.owner, .administrator)
        XCTAssertEqual(AppBundleInspector.fileOwner(bundle), .user)
    }

    func testVendorUninstallerNextToTheAppIsFound() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let suite = fixture.system.appendingPathComponent("Applications/Adobe Foo", isDirectory: true)
        let bundle = try fixture.app("Adobe Foo", bundleID: "com.adobe.foo", in: suite)
        let uninstaller = try fixture.app("Uninstall Adobe Foo", bundleID: "com.adobe.foo.uninstaller", in: suite)
        try fixture.app("Uninstall Other Thing", bundleID: "com.example.other.uninstaller", in: suite)
        XCTAssertEqual(try inspector.identity(of: bundle).vendorUninstaller, uninstaller.standardizedFileURL.path)
        let inside = try fixture.app("Bar", bundleID: "com.example.bar")
        let resources = inside.appendingPathComponent("Contents/Resources", isDirectory: true)
        let bundled = try fixture.app("Bar Uninstaller", bundleID: "com.example.bar.uninstaller", in: resources)
        XCTAssertEqual(try inspector.identity(of: inside).vendorUninstaller, bundled.standardizedFileURL.path)
        XCTAssertNil(try inspector.identity(of: try fixture.app("Lonely", bundleID: "com.example.lonely")).vendorUninstaller)
    }

    func testAFolderWithoutInfoPlistIsNotAnApp() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let folder = fixture.system.appendingPathComponent("Applications/Broken.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try inspector.identity(of: folder.deletingLastPathComponent())) {
            XCTAssertEqual($0 as? FrogError, .message("Frog cannot read this app."))
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Broken"], format: .xml, options: 0)
        try plist.write(to: folder.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try inspector.identity(of: folder.deletingLastPathComponent()))
    }
}
