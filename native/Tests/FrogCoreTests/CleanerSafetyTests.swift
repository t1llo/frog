import XCTest
@testable import FrogCore

final class CleanerSafetyTests: XCTestCase {
    private let invalid = "Frog cannot use this path."
    private let trash = "This item is already in the Trash."
    private let own = "Frog never moves its own files."
    private let apple = "Frog never moves Apple's own files."
    private let synced = "Frog never moves iCloud or synced folders."
    private let personal = "Frog never moves mail, messages, Safari, Photos or keychain data."
    private let library = "Frog never moves a whole Library folder."
    private let link = "This path goes through a link, so Frog cannot be sure where it points."
    private let restricted = "macOS protects this item."
    private let outside = "This item is outside the folders Frog cleans."

    func testAppleItemsICloudMailAndKeychainsAreRefusedWithTheirSentence() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let frogData = fixture.home.appendingPathComponent("Library/Application Support/Frog")
        let safety = CleanerSafety(roots: fixture.roots, protectedPaths: [frogData])
        let home = fixture.home, system = fixture.system
        func refusal(_ url: URL, _ purpose: CleanerSafety.Purpose = .leftover) -> String? { safety.refusal(for: url, purpose: purpose) }

        XCTAssertEqual(refusal(URL(string: "Library/Caches/com.example")!), invalid)
        XCTAssertEqual(refusal(URL(fileURLWithPath: home.path + "/Library/Caches/../Caches/com.example")), invalid)
        XCTAssertEqual(refusal(home.appendingPathComponent(".Trash/Old.app"), .junk), trash)
        XCTAssertEqual(refusal(frogData.appendingPathComponent("history.json")), own)
        XCTAssertEqual(refusal(home.appendingPathComponent("Library/Caches/com.apple.Safari")), apple)
        XCTAssertEqual(refusal(home.appendingPathComponent("Library/Application Support/CloudDocs")), apple)
        XCTAssertEqual(refusal(system.appendingPathComponent("System/Library/Caches/x"), .disk), apple)
        XCTAssertEqual(refusal(system.appendingPathComponent("Library/Apple/usr/x"), .disk), apple)
        XCTAssertEqual(refusal(home.appendingPathComponent("Library/Mobile Documents/com~example~notes"), .junk), synced)
        XCTAssertEqual(refusal(home.appendingPathComponent("Library/CloudStorage/Dropbox"), .junk), synced)
        XCTAssertEqual(refusal(home.appendingPathComponent("Library/Keychains/login.keychain-db"), .junk), personal)
        XCTAssertEqual(refusal(home.appendingPathComponent("Library/Mail/V10"), .junk), personal)
        XCTAssertEqual(refusal(home.appendingPathComponent("Library/Messages"), .junk), personal)
        XCTAssertEqual(refusal(home.appendingPathComponent("Library/Safari/History.db"), .junk), personal)
        XCTAssertEqual(refusal(home.appendingPathComponent("Pictures/Photos Library.photoslibrary"), .disk), personal)
        XCTAssertEqual(refusal(home.appendingPathComponent("Library/Caches")), library)
        let target = fixture.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let linked = home.appendingPathComponent("Library/Caches/linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        XCTAssertEqual(refusal(linked.appendingPathComponent("x")), link)
        let flagged = CleanerSafety(roots: fixture.roots, fileFlags: { _ in 0x0008_0000 })
        XCTAssertEqual(flagged.refusal(for: home.appendingPathComponent("Library/Caches/com.example"), purpose: .leftover), restricted)
        XCTAssertEqual(refusal(home.appendingPathComponent("Documents/notes.txt")), outside)
        XCTAssertNil(refusal(home.appendingPathComponent("Library/Caches/com.example")))
    }

    func testAppleTeamPrefixedGroupsAndShortcutsAreApple() throws {
        for name in ["com.apple.Safari", "group.com.apple.notes", "243LU875E5.groups.com.apple.podcasts",
                     "K36BKF7T3D.group.com.apple.configurator", "group.is.workflow.my.app", "is.workflow.shortcuts",
                     "COM.APPLE.dock.plist"] {
            XCTAssertTrue(CleanerSafety.isAppleName(name), name)
        }
        for name in ["com.example.app", "com.applesauce.app", "Apple Notes Exporter", "my.is.workflow"] {
            XCTAssertFalse(CleanerSafety.isAppleName(name), name)
        }
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let safety = CleanerSafety(roots: fixture.roots)
        let group = try fixture.item(.groupContainers, "243LU875E5.groups.com.apple.podcasts")
        XCTAssertEqual(safety.refusal(for: group, purpose: .leftover), apple)
        let other = try fixture.item(.groupContainers, "ABCDE12345.com.example.shared")
        XCTAssertNil(safety.refusal(for: other, purpose: .leftover))
    }

    func testAFixtureUnderTheTemporaryFolderIsAllowedInEitherSpelling() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        XCTAssertTrue(fixture.home.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let safety = CleanerSafety(roots: fixture.roots)
        let cache = try fixture.item(.caches, "com.example.app")
        let given = cache.standardizedFileURL.path
        let resolved = given.hasPrefix("/var/") ? "/private" + given : given
        XCTAssertNil(safety.refusal(for: URL(fileURLWithPath: given), purpose: .leftover))
        XCTAssertNil(safety.refusal(for: URL(fileURLWithPath: resolved), purpose: .leftover))
        let real = fixture.root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("inner"), withIntermediateDirectories: true)
        let parentLink = fixture.home.appendingPathComponent("Library/Application Support/Linked")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: real)
        XCTAssertEqual(safety.refusal(for: parentLink.appendingPathComponent("inner"), purpose: .leftover), link)
        XCTAssertEqual(safety.refusal(for: URL(fileURLWithPath: fixture.roots.resolved(parentLink).path + "/inner"),
                                      purpose: .leftover), link)
    }

    func testLibraryFoldersThemselvesAreNeverOffered() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let safety = CleanerSafety(roots: fixture.roots)
        let folders = [fixture.home, fixture.home.appendingPathComponent("Library"),
                       fixture.home.appendingPathComponent("Library/Caches"),
                       fixture.home.appendingPathComponent("Library/Preferences/ByHost"),
                       fixture.system, fixture.system.appendingPathComponent("Library"),
                       fixture.system.appendingPathComponent("Library/LaunchDaemons")]
        for folder in folders {
            for purpose in [CleanerSafety.Purpose.leftover, .junk, .disk] {
                XCTAssertEqual(safety.refusal(for: folder, purpose: purpose), library, folder.path)
            }
        }
    }

    func testAPathThroughALinkIsRefusedButALinkItselfIsAllowed() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let safety = CleanerSafety(roots: fixture.roots)
        let target = fixture.root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("child"), withIntermediateDirectories: true)
        let itemLink = fixture.home.appendingPathComponent("Library/Caches/com.example.link")
        try FileManager.default.createSymbolicLink(at: itemLink, withDestinationURL: target)
        XCTAssertNil(safety.refusal(for: itemLink, purpose: .leftover))
        XCTAssertEqual(safety.refusal(for: itemLink.appendingPathComponent("child"), purpose: .leftover), link)
        let logs = fixture.home.appendingPathComponent("Library/Logs/Vendor")
        try FileManager.default.createSymbolicLink(at: logs, withDestinationURL: target)
        XCTAssertEqual(safety.refusal(for: logs.appendingPathComponent("child/deeper.log"), purpose: .junk), link)
    }

    func testRestrictedFlagIsRefused() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let cache = try fixture.item(.caches, "com.example.app")
        let restrictedSafety = CleanerSafety(roots: fixture.roots, fileFlags: { _ in 0x0008_0000 | 0x0000_0001 })
        XCTAssertEqual(restrictedSafety.refusal(for: cache, purpose: .leftover), restricted)
        let plain = CleanerSafety(roots: fixture.roots, fileFlags: { _ in 0x0000_0001 })
        XCTAssertNil(plain.refusal(for: cache, purpose: .leftover))
        XCTAssertNil(CleanerSafety(roots: fixture.roots).refusal(for: cache, purpose: .leftover))
    }

    func testEachPurposeAcceptsOnlyItsOwnFolders() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let safety = CleanerSafety(roots: fixture.roots)
        let home = fixture.home, system = fixture.system
        let app = home.appendingPathComponent("Applications/Sub/Foo.app")
        let systemApp = system.appendingPathComponent("Applications/Suite/Tools/Extra/Bar.app")
        let leftover = home.appendingPathComponent("Library/Caches/x")
        let systemLeftover = system.appendingPathComponent("Library/Application Support/com.example")
        let junk = home.appendingPathComponent("Downloads/Installer.dmg")

        XCTAssertNil(safety.refusal(for: app, purpose: .application))
        XCTAssertNil(safety.refusal(for: systemApp, purpose: .application))
        XCTAssertNil(safety.refusal(for: leftover, purpose: .leftover))
        XCTAssertNil(safety.refusal(for: systemLeftover, purpose: .leftover))
        XCTAssertNil(safety.refusal(for: junk, purpose: .junk))
        XCTAssertNil(safety.refusal(for: junk, purpose: .disk))

        XCTAssertEqual(safety.refusal(for: app, purpose: .leftover), outside)
        XCTAssertEqual(safety.refusal(for: leftover, purpose: .application), outside)
        XCTAssertEqual(safety.refusal(for: junk, purpose: .application), outside)
        XCTAssertEqual(safety.refusal(for: junk, purpose: .leftover), outside)
        XCTAssertEqual(safety.refusal(for: systemLeftover, purpose: .junk), outside)
        XCTAssertEqual(safety.refusal(for: systemLeftover, purpose: .disk), outside)
        XCTAssertEqual(safety.refusal(for: home.appendingPathComponent("Applications/a/b/c/d/Deep.app"), purpose: .application), outside)
        XCTAssertEqual(safety.refusal(for: home.appendingPathComponent("Applications/Foo.app/Contents/Helper.app"), purpose: .application), outside)
        XCTAssertEqual(safety.refusal(for: home.appendingPathComponent("Applications/Notes.txt"), purpose: .application), outside)
        XCTAssertEqual(safety.refusal(for: URL(fileURLWithPath: "/Volumes/Other/Foo.app"), purpose: .application), outside)
    }

    func testWithTheRealSystemRootAHomeUnderPrivateIsStillUsable() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        // The temporary home resolves to /private/var/...; the system rule for /private must not cover it.
        let safety = CleanerSafety(roots: CleanerRoots(home: fixture.home), fileFlags: { _ in nil })
        XCTAssertNil(safety.refusal(for: fixture.home.appendingPathComponent("Library/Caches/com.example"), purpose: .leftover))
        XCTAssertEqual(safety.refusal(for: URL(fileURLWithPath: "/System/Library/Caches/x"), purpose: .disk), apple)
        XCTAssertEqual(safety.refusal(for: URL(fileURLWithPath: "/usr/local/bin/tool"), purpose: .disk), apple)
        XCTAssertEqual(safety.refusal(for: URL(fileURLWithPath: "/private/var/db/x"), purpose: .leftover), apple)
        XCTAssertEqual(safety.refusal(for: URL(fileURLWithPath: "/"), purpose: .disk), library)
        XCTAssertEqual(safety.refusal(for: URL(fileURLWithPath: "/Library/Caches"), purpose: .leftover), library)
    }

    func testFrogsOwnFilesAreRefused() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let bundle = fixture.system.appendingPathComponent("Applications/Frog.app")
        let data = fixture.home.appendingPathComponent("Library/Application Support/Frog")
        let config = fixture.home.appendingPathComponent(".config/frog")
        let safety = CleanerSafety(roots: fixture.roots, protectedPaths: [bundle, data, config])
        XCTAssertEqual(safety.refusal(for: bundle, purpose: .application), own)
        XCTAssertEqual(safety.refusal(for: data, purpose: .leftover), own)
        XCTAssertEqual(safety.refusal(for: data.appendingPathComponent("Cleaner/removals.json"), purpose: .leftover), own)
        XCTAssertEqual(safety.refusal(for: config.appendingPathComponent("config"), purpose: .junk), own)
        XCTAssertNil(safety.refusal(for: fixture.home.appendingPathComponent("Library/Application Support/Frogger"), purpose: .leftover))
        XCTAssertNil(safety.refusal(for: fixture.system.appendingPathComponent("Applications/Frogger.app"), purpose: .application))
    }
}
