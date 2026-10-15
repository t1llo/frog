import XCTest
@testable import FrogCore

final class LeftoverMatcherTests: XCTestCase {
    private func app(_ name: String, _ bundleID: String, nested: [String] = [], groups: [String] = [],
                     teamID: String? = nil, executable: String? = nil) -> AppIdentity {
        AppIdentity(path: "/Applications/\(name).app", name: name, bundleID: bundleID, executableName: executable,
                    teamID: teamID, appGroups: groups, nestedBundleIDs: nested)
    }

    func testExactBundleIDAndItsSeparatorsAreCertain() {
        let matcher = LeftoverMatcher(app: app("Example", "com.example.app"), otherApps: [])
        for name in ["com.example.app", "com.example.app.plist", "com.example.app.savedState",
                     "com.example.app.binarycookies", "com.example.app.0A1B2C3D-4E5F-6789-ABCD-EF0123456789.plist",
                     "COM.Example.App.plist"] {
            let match = matcher.match(name: name, location: .preferences)
            XCTAssertEqual(match?.confidence, .certain, name)
            XCTAssertEqual(match?.reason, "Named after the bundle ID com.example.app.", name)
            XCTAssertEqual(match?.sharedWith, [], name)
        }
    }

    func testAnIDWithoutSeparatorIsNotAMatch() {
        let matcher = LeftoverMatcher(app: app("Foo", "com.foo.app"), otherApps: [])
        XCTAssertNil(matcher.match(name: "com.foo.application.plist", location: .preferences))
        XCTAssertNil(matcher.match(name: "com.foo.ap", location: .caches))
    }

    func testALongerIDOfAnotherInstalledAppWins() {
        let foo = app("Foo Suite", "com.foo")
        let bar = app("Bar", "com.foo.bar")
        let matcher = LeftoverMatcher(app: foo, otherApps: [bar])
        XCTAssertNil(matcher.match(name: "com.foo.bar.plist", location: .preferences))
        XCTAssertNil(matcher.match(name: "com.foo.bar", location: .caches))
        XCTAssertEqual(matcher.match(name: "com.foo.plist", location: .preferences)?.confidence, .certain)
        XCTAssertEqual(matcher.match(name: "com.foo.baz.plist", location: .preferences)?.confidence, .certain)
        // From the other side the item is Bar's, and Foo does not share it.
        let barMatch = LeftoverMatcher(app: bar, otherApps: [foo]).match(name: "com.foo.bar.plist", location: .preferences)
        XCTAssertEqual(barMatch?.confidence, .certain)
        XCTAssertEqual(barMatch?.sharedWith, [])
    }

    func testNestedHelperAndAppGroupMatchesAreCertainWithTheirReasons() {
        let example = app("Example", "com.example.app", nested: ["com.example.app.helper"],
                          groups: ["9ABCDE.com.example"])
        let matcher = LeftoverMatcher(app: example, otherApps: [])
        let helper = matcher.match(name: "com.example.app.helper.plist", location: .preferences)
        XCTAssertEqual(helper?.confidence, .certain)
        XCTAssertEqual(helper?.reason, "Named after com.example.app.helper, a part of Example.")
        let group = matcher.match(name: "9ABCDE.com.example", location: .groupContainers)
        XCTAssertEqual(group?.confidence, .certain)
        XCTAssertEqual(group?.reason, "Named after the app group 9ABCDE.com.example.")
    }

    func testAnExactDistinctiveNameIsLikelyButGenericOrShortNamesAreNot() {
        let slack = LeftoverMatcher(app: app("Slack", "com.tinyspeck.slackmacgap"), otherApps: [])
        let match = slack.match(name: "Slack", location: .applicationSupport)
        XCTAssertEqual(match?.confidence, .likely)
        XCTAssertEqual(match?.reason, "Folder named Slack.")
        XCTAssertEqual(slack.match(name: "slack", location: .caches)?.confidence, .likely)
        // Only folders in data locations count as likely.
        XCTAssertNotEqual(slack.match(name: "Slack", location: .preferences)?.confidence, .likely)

        for name in ["Notes", "Code", "Foo"] {
            let matcher = LeftoverMatcher(app: app(name, "com.example.\(name.lowercased())x"), otherApps: [])
            XCTAssertNil(matcher.match(name: name, location: .applicationSupport), name)
            XCTAssertFalse(LeftoverMatcher.isDistinctive(name), name)
        }
        XCTAssertTrue(LeftoverMatcher.isDistinctive("Slack"))
        XCTAssertTrue(LeftoverMatcher.isDistinctive("Frog"))
        XCTAssertFalse(LeftoverMatcher.isDistinctive("NOTES"))
    }

    func testBundleIDShapeNeedsThreeComponentsAndAKnownFirstOne() {
        for name in ["com.example.app", "org.mozilla.firefox", "de.example.tool", "io.github.some-app_2"] {
            XCTAssertTrue(LeftoverMatcher.isBundleIDShaped(name), name)
        }
        for name in ["Slack", "test.example.app", "com.example", "com..app", "com.example.app plist",
                     "com.example." + String(repeating: "a", count: 65)] {
            XCTAssertFalse(LeftoverMatcher.isBundleIDShaped(name), name)
        }
    }

    func testANameAnotherInstalledAppAlsoUsesIsShared() {
        let example = app("Example", "com.example.app", groups: ["group.com.example.shared"])
        let other = app("Example Pro", "com.example.pro", groups: ["group.com.example.shared"], executable: "Example")
        let twin = AppIdentity(path: "/Users/Shared/Example.app", name: "Example", bundleID: "com.example.app")
        let matcher = LeftoverMatcher(app: example, otherApps: [other, twin])

        let folder = matcher.match(name: "Example", location: .applicationSupport)
        XCTAssertEqual(folder?.confidence, .likely)
        XCTAssertEqual(folder?.sharedWith, ["Example Pro", "Example"])
        let group = matcher.match(name: "group.com.example.shared", location: .groupContainers)
        XCTAssertEqual(group?.confidence, .certain)
        XCTAssertEqual(group?.sharedWith, ["Example Pro"])
        let preferences = matcher.match(name: "com.example.app.plist", location: .preferences)
        XCTAssertEqual(preferences?.sharedWith, ["Example"])

        let item = CleanerItem(url: URL(fileURLWithPath: "/tmp/Example"), kind: .folder, confidence: folder!.confidence,
                               reason: folder!.reason, sharedWith: folder!.sharedWith)
        XCTAssertFalse(item.isPreselected)
        // A folder named exactly after another installed app belongs to that app.
        XCTAssertNil(LeftoverMatcher(app: app("Slack", "com.tinyspeck.slackmacgap"),
                                     otherApps: [app("Slack Notes", "com.other.notes")])
            .match(name: "Slack Notes", location: .applicationSupport))
    }

    func testContainsTeamPrefixAndVendorLabelMatchesArePossibleOnly() {
        let example = app("Example", "com.vendor.exampleapp", groups: ["ABCDE12345.com.vendor.example"],
                          teamID: "ABCDE12345")
        let sibling = app("Other", "com.vendor.other", teamID: "ABCDE12345")
        let matcher = LeftoverMatcher(app: example, otherApps: [sibling])

        let contains = matcher.match(name: "Example Crashpad", location: .applicationSupport)
        XCTAssertEqual(contains?.confidence, .possible)
        XCTAssertEqual(contains?.reason, "Name contains Example.")
        XCTAssertEqual(matcher.match(name: "exampleapp-cache.db", location: .caches)?.reason, "Name contains exampleapp.")

        let team = matcher.match(name: "ABCDE12345.com.vendor.settings", location: .groupContainers)
        XCTAssertEqual(team?.confidence, .possible)
        XCTAssertEqual(team?.reason, "Starts with the developer's team ID.")
        XCTAssertEqual(team?.sharedWith, ["Other"])

        let plist = LaunchPlist(url: URL(fileURLWithPath: "/Library/LaunchAgents/com.vendor.updater.plist"),
                                label: "com.vendor.updater", program: "/Library/Vendor/updater")
        let vendor = matcher.match(launchPlist: plist)
        XCTAssertEqual(vendor?.confidence, .possible)
        XCTAssertEqual(vendor?.reason, "Label shares Example's developer prefix.")
        XCTAssertEqual(vendor?.sharedWith, ["Other"])

        XCTAssertNil(matcher.match(name: "Unrelated", location: .applicationSupport))
    }

    func testLaunchPlistIntoTheBundleIsCertainAndIntoAnotherAppIsNotMatched() {
        let example = app("Example", "com.example.app", nested: ["com.example.app.helper"])
        let other = app("Other", "com.other.app")
        let matcher = LeftoverMatcher(app: example, otherApps: [other])
        func plist(_ label: String, program: String? = nil, associated: [String] = []) -> LaunchPlist {
            LaunchPlist(url: URL(fileURLWithPath: "/Library/LaunchAgents/\(label).plist"), label: label,
                        program: program, associatedBundleIDs: associated)
        }

        let inside = matcher.match(launchPlist: plist("org.unrelated.job",
                                                      program: "/Applications/Example.app/Contents/MacOS/agent"))
        XCTAssertEqual(inside?.confidence, .certain)
        XCTAssertEqual(inside?.reason, "Starts a program inside Example.app.")

        let declared = matcher.match(launchPlist: plist("org.unrelated.job", associated: ["com.example.app"]))
        XCTAssertEqual(declared?.confidence, .certain)
        XCTAssertEqual(declared?.reason, "Declares Example as its app.")

        let label = matcher.match(launchPlist: plist("com.example.app.helper.daemon", program: "/usr/local/bin/x"))
        XCTAssertEqual(label?.confidence, .certain)
        XCTAssertEqual(label?.reason, "Its label is Example's bundle ID.")

        XCTAssertNil(matcher.match(launchPlist: plist("com.example.app.agent",
                                                      program: "/Applications/Other.app/Contents/MacOS/agent")))
        XCTAssertNil(matcher.match(launchPlist: plist("org.unrelated.job", associated: ["com.other.app"])))
        XCTAssertNil(matcher.match(launchPlist: plist("org.unrelated.job",
                                                      program: "/Applications/Example.application/agent")))
    }

    func testLaunchPlistIsReadFromXMLAndBinaryAndNeedsALabel() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ plist: [String: Any], _ name: String, format: PropertyListSerialization.PropertyListFormat) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: url)
            return url
        }
        let xml = try write(["Label": "com.example.agent", "ProgramArguments": ["/opt/example/agent", "--run"],
                             "AssociatedBundleIdentifiers": "com.example.app", "RunAtLoad": true,
                             "KeepAlive": ["SuccessfulExit": false]], "a.plist", format: .xml)
        let read = try XCTUnwrap(LaunchPlist.read(xml))
        XCTAssertEqual(read.label, "com.example.agent")
        XCTAssertEqual(read.program, "/opt/example/agent")
        XCTAssertEqual(read.associatedBundleIDs, ["com.example.app"])
        XCTAssertTrue(read.runAtLoad)
        XCTAssertTrue(read.keepAlive)
        XCTAssertFalse(read.disabled)

        let binary = try write(["Label": "com.example.daemon", "Program": "/opt/example/daemon", "KeepAlive": false,
                                "Disabled": true], "b.plist", format: .binary)
        XCTAssertEqual(LaunchPlist.read(binary)?.program, "/opt/example/daemon")
        XCTAssertEqual(LaunchPlist.read(binary)?.keepAlive, false)
        XCTAssertEqual(LaunchPlist.read(binary)?.disabled, true)

        XCTAssertNil(LaunchPlist.read(try write(["Program": "/x"], "c.plist", format: .xml)))
        let large = folder.appendingPathComponent("d.plist")
        try Data(count: 300_000).write(to: large)
        XCTAssertNil(LaunchPlist.read(large))
        XCTAssertNil(LaunchPlist.read(folder.appendingPathComponent("missing.plist")))
    }
}
