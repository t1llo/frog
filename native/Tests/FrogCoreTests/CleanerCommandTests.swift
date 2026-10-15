import XCTest
@testable import FrogCore

final class CleanerCommandTests: XCTestCase {
    private let folders = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                           URL(fileURLWithPath: "/fixture-home/Applications", isDirectory: true)]

    private func offers(_ path: String, _ bundleID: String?, own: String = "/Applications/Frog.app") -> Bool {
        CleanerCommand.offers(path: path, bundleID: bundleID, ownBundlePath: own, applicationFolders: folders)
    }

    func testUninstallAndRemoveTakeTheRestAsTheAppName() {
        XCTAssertEqual(CleanerCommand.appQuery("uninstall slack"), "slack")
        XCTAssertEqual(CleanerCommand.appQuery("Remove  Slack "), "Slack")
        XCTAssertEqual(CleanerCommand.appQuery("UNINSTALL sl"), "sl")
        XCTAssertEqual(CleanerCommand.appQuery("  remove visual studio code"), "visual studio code")
    }

    func testOtherQueriesAndBareVerbsOfferNothing() {
        for query in ["uninstall", "uninstall ", "remove", "uninstall s", "removed slack", "slack uninstall", "uninstallslack", ""] {
            XCTAssertNil(CleanerCommand.appQuery(query), query)
        }
    }

    func testFinderAppleAppsAndFrogItselfGetNoRow() {
        XCTAssertFalse(offers("/System/Library/CoreServices/Finder.app", "com.apple.finder"))
        XCTAssertFalse(offers("/System/Applications/Notes.app", "com.apple.Notes"))
        XCTAssertFalse(offers("/Applications/Safari.app", "com.apple.Safari"))
        XCTAssertFalse(offers("/Applications/Frog.app", "com.example.frog"))
        XCTAssertFalse(offers("/Volumes/X/Foo.app", "com.example.foo"))
        XCTAssertFalse(offers("/Applications/Suite.app/Contents/Helper.app", "com.example.helper"), "Part of another app")
        XCTAssertFalse(offers("/Applications/a/b/c/d/Deep.app", "com.example.deep"))
        XCTAssertTrue(offers("/Applications/Utilities/Foo.app", "com.example.foo"))
        XCTAssertTrue(offers("/fixture-home/Applications/Bar.app", nil))
        XCTAssertTrue(offers("/Applications/a/b/c/Suite Part.app", "com.example.part"))
    }

    func testRowIDsRoundTripPathsWithSpaces() {
        let path = "/Applications/Visual Studio Code.app"
        let id = CleanerCommand.rowID(path: path)
        XCTAssertEqual(id, "uninstall:/Applications/Visual Studio Code.app")
        XCTAssertEqual(CleanerCommand.path(fromRowID: id), path)
        XCTAssertNil(CleanerCommand.path(fromRowID: "app:" + path))
        XCTAssertNil(CleanerCommand.path(fromRowID: "uninstall:"))
    }
}
