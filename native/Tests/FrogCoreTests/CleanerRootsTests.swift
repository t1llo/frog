import XCTest
@testable import FrogCore

final class CleanerRootsTests: XCTestCase {
    func testEveryLocationResolvesOnlyInItsDomains() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let roots = fixture.roots
        XCTAssertEqual(roots.folder(.caches, .user)?.path, roots.home.path + "/Library/Caches")
        XCTAssertEqual(roots.folder(.caches, .system)?.path, roots.system.path + "/Library/Caches")
        XCTAssertEqual(roots.folder(.byHostPreferences, .user)?.path, roots.home.path + "/Library/Preferences/ByHost")
        XCTAssertNil(roots.folder(.containers, .system))
        XCTAssertNil(roots.folder(.launchDaemons, .user))
        XCTAssertNil(roots.folder(.privilegedHelperTools, .user))
        XCTAssertEqual(roots.folder(.launchDaemons, .system)?.path, roots.system.path + "/Library/LaunchDaemons")
        for location in LeftoverLocation.allCases {
            for domain in [CleanerDomain.user, .system] {
                XCTAssertEqual(roots.folder(location, domain) != nil, location.domains.contains(domain), "\(location) \(domain)")
                if let folder = roots.folder(location, domain) {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), folder.path)
                }
            }
        }
        XCTAssertEqual(roots.applicationFolders.map(\.path), [roots.system.path + "/Applications", roots.home.path + "/Applications"])
        XCTAssertEqual(LeftoverLocation.containers.itemKind, .container)
        XCTAssertEqual(LeftoverLocation.byHostPreferences.itemKind, .preferences)
        XCTAssertEqual(LeftoverLocation.caches.itemKind, .folder)
        XCTAssertTrue(LeftoverLocation.groupContainers.probesOnly)
        XCTAssertFalse(LeftoverLocation.caches.probesOnly)
        XCTAssertTrue(LeftoverLocation.cookies.needsFullDiskAccess)
    }

    func testDisplayPathAbbreviatesHomeOnly() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let roots = fixture.roots
        let cache = try fixture.item(.caches, "com.example")
        XCTAssertEqual(roots.displayPath(cache), "~/Library/Caches/com.example")
        XCTAssertEqual(roots.displayPath(roots.resolved(cache)), "~/Library/Caches/com.example")
        XCTAssertEqual(roots.displayPath(fixture.home), "~")
        let systemCache = try fixture.item(.caches, "com.example", domain: .system)
        XCTAssertEqual(roots.displayPath(systemCache), roots.system.path + "/Library/Caches/com.example")
        // A sibling whose name starts like home is not inside it.
        let sibling = fixture.root.appendingPathComponent("homework")
        XCTAssertEqual(roots.displayPath(sibling), roots.resolved(sibling).path)
        XCTAssertFalse(roots.displayPath(sibling).hasPrefix("~"))
    }

    func testRootsResolveWithRealpathAndRewriteTheUnresolvedSpelling() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let roots = fixture.roots
        let given = fixture.home.standardizedFileURL.path
        let real = given.hasPrefix("/var/") ? "/private" + given : given
        XCTAssertEqual(roots.home.path, real)
        let cache = fixture.home.appendingPathComponent("Library/Caches/com.example")
        XCTAssertEqual(roots.resolved(cache).path, real + "/Library/Caches/com.example")
        XCTAssertEqual(roots.resolved(URL(fileURLWithPath: real + "/Library")).path, real + "/Library")
        XCTAssertEqual(roots.resolved(fixture.home).path, real)
        XCTAssertEqual(roots.resolved(URL(fileURLWithPath: "/Applications/Other.app")).path, "/Applications/Other.app")
        // A root that does not exist stays as given.
        let missing = fixture.root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertEqual(CleanerRoots(home: missing, system: fixture.system).home.path, missing.standardizedFileURL.path)
        XCTAssertEqual(CleanerRoots(home: fixture.home, system: fixture.system), roots)
    }
}
