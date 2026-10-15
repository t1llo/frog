import XCTest
@testable import FrogCore

final class LeftoverScannerTests: XCTestCase {
    private struct Signatures: CodeSignatureReading {
        var groups: [String]
        func signature(of bundle: URL) -> CodeSignatureInfo? { CodeSignatureInfo(teamID: "ABCDE12345", appGroups: groups) }
    }

    /// Records calls from the scanner's `@Sendable` file-system closures.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func record(_ url: URL) { lock.lock(); paths.append(url.path); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    private func identity(_ bundle: URL, groups: [String] = []) throws -> AppIdentity {
        try AppBundleInspector(signatures: Signatures(groups: groups)).identity(of: bundle)
    }

    private func scanner(_ fixture: CleanerFixture, fileSystem: CleanerFileSystem = .live,
                         hasFullDiskAccess: Bool = true) -> LeftoverScanner {
        LeftoverScanner(roots: fixture.roots, safety: CleanerSafety(roots: fixture.roots), fileSystem: fileSystem,
                        hasFullDiskAccess: hasFullDiskAccess)
    }

    /// Items keep the standardized spelling, which may drop `/private` from the temporary folder.
    private func item(_ items: [CleanerItem], _ fixture: CleanerFixture, _ url: URL) -> CleanerItem? {
        let path = fixture.roots.resolved(url).path
        return items.first { fixture.roots.resolved($0.url).path == path }
    }

    func testScanFindsTheBundleFirstThenLeftoversByConfidence() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try identity(fixture.app("Example", bundleID: "com.example.app"))
        let caches = try fixture.item(.caches, "com.example.app")
        let support = try fixture.item(.applicationSupport, "Example")
        let preferences = try fixture.item(.preferences, "com.example.app.plist", directory: false)
        let saved = try fixture.item(.savedState, "com.example.app.savedState")
        let crashpad = try fixture.item(.applicationSupport, "Example Crashpad")
        let log = try fixture.item(.logs, "Example.log", directory: false)
        let agent = try fixture.launchPlist(.launchAgents, label: "com.example.app.agent")
        try fixture.item(.applicationSupport, "Unrelated")
        try fixture.item(.caches, ".DS_Store", directory: false)

        let items = try scanner(fixture).scan(app: app, otherApps: [])

        XCTAssertEqual(items.first?.kind, .application)
        XCTAssertEqual(items.first?.reason, "The app itself.")
        XCTAssertNotNil(item(Array(items.prefix(1)), fixture, URL(fileURLWithPath: app.path)))
        XCTAssertEqual(items.count, 8)
        XCTAssertEqual(item(items, fixture, caches)?.confidence, .certain)
        XCTAssertEqual(item(items, fixture, support)?.confidence, .likely)
        XCTAssertEqual(item(items, fixture, support)?.kind, .folder)
        XCTAssertEqual(item(items, fixture, preferences)?.kind, .preferences)
        XCTAssertEqual(item(items, fixture, saved)?.confidence, .certain)
        XCTAssertEqual(item(items, fixture, crashpad)?.confidence, .possible)
        XCTAssertEqual(item(items, fixture, log)?.kind, .file)
        XCTAssertEqual(item(items, fixture, agent)?.kind, .launchAgent)
        XCTAssertEqual(item(items, fixture, agent)?.launchLabel, "com.example.app.agent")

        let leftovers = Array(items.dropFirst())
        for (earlier, later) in zip(leftovers, leftovers.dropFirst()) {
            XCTAssertTrue(earlier.confidence > later.confidence
                          || (earlier.confidence == later.confidence && earlier.url.path < later.url.path))
        }
    }

    func testContainersAreProbedNotListed() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try identity(fixture.app("Example", bundleID: "com.example.app"), groups: ["ABCDE12345.com.example"])
        let container = try fixture.item(.containers, "com.example.app")
        let group = try fixture.item(.groupContainers, "ABCDE12345.com.example")
        try fixture.item(.containers, "com.example.app.other")
        let listed = Calls()
        var fileSystem = CleanerFileSystem.live
        let live = fileSystem.contents
        fileSystem.contents = { url in listed.record(url); return try live(url) }

        let items = try scanner(fixture, fileSystem: fileSystem).scan(app: app, otherApps: [])

        XCTAssertFalse(listed.all.isEmpty)
        XCTAssertFalse(listed.all.contains { $0.hasSuffix("/Containers") || $0.hasSuffix("/Group Containers") })
        XCTAssertEqual(item(items, fixture, container)?.kind, .container)
        XCTAssertEqual(item(items, fixture, container)?.reason, "Named after the bundle ID com.example.app.")
        XCTAssertEqual(item(items, fixture, container)?.needsFullDiskAccess, false)
        XCTAssertEqual(item(items, fixture, group)?.kind, .groupContainer)
        XCTAssertEqual(item(items, fixture, group)?.reason, "Named after the app group ABCDE12345.com.example.")
        XCTAssertFalse(items.contains { $0.url.lastPathComponent == "com.example.app.other" })
    }

    func testSystemDomainItemsCarryTheirOwner() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try identity(fixture.app("Example", bundleID: "com.example.app"))
        let systemSupport = try fixture.item(.applicationSupport, "com.example.app", domain: .system)
        let helper = try fixture.item(.privilegedHelperTools, "com.example.app.helper", domain: .system, directory: false)
        let daemon = try fixture.launchPlist(.launchDaemons, label: "com.example.app.daemon", domain: .system)
        let userCaches = try fixture.item(.caches, "com.example.app")
        let systemPath = fixture.roots.system.path + "/"
        var fileSystem = CleanerFileSystem.live
        let roots = fixture.roots
        fileSystem.owner = { roots.resolved($0).path.hasPrefix(systemPath + "Library/") ? .administrator : .user }

        let items = try scanner(fixture, fileSystem: fileSystem).scan(app: app, otherApps: [])

        XCTAssertEqual(item(items, fixture, systemSupport)?.owner, .administrator)
        XCTAssertEqual(item(items, fixture, helper)?.owner, .administrator)
        XCTAssertEqual(item(items, fixture, helper)?.kind, .helperTool)
        XCTAssertEqual(item(items, fixture, daemon)?.owner, .administrator)
        XCTAssertEqual(item(items, fixture, daemon)?.kind, .launchDaemon)
        XCTAssertEqual(item(items, fixture, userCaches)?.owner, .user)
    }

    func testVendorFolderIsPossibleButTheAppFolderInsideItIsLikely() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try identity(fixture.app("Example", bundleID: "com.acmesoft.example"))
        let vendor = try fixture.item(.applicationSupport, "AcmeSoft")
        let inside = try fixture.item(.applicationSupport, "AcmeSoft/Example")
        try fixture.item(.applicationSupport, "AcmeSoft/Other")
        let cachesVendor = try fixture.item(.caches, "acmesoft")

        let items = try scanner(fixture).scan(app: app, otherApps: [])

        XCTAssertEqual(item(items, fixture, vendor)?.confidence, .possible)
        XCTAssertEqual(item(items, fixture, vendor)?.reason, "Folder of the developer, AcmeSoft.")
        XCTAssertEqual(item(items, fixture, inside)?.confidence, .likely)
        XCTAssertEqual(item(items, fixture, inside)?.reason, "Folder Example inside AcmeSoft.")
        XCTAssertEqual(item(items, fixture, cachesVendor)?.reason, "Folder of the developer, acmesoft.")
        XCTAssertFalse(items.contains { $0.url.lastPathComponent == "Other" })
        XCTAssertFalse(item(items, fixture, vendor)!.isPreselected)
        XCTAssertTrue(item(items, fixture, inside)!.isPreselected)
    }

    func testAppleAndICloudItemsNeverAppearEvenWithMatchingNames() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let bundle = try fixture.app("Example", bundleID: "com.example.app", bundleName: "CloudDocs")
        let app = try identity(bundle, groups: ["group.com.apple.example"])
        try fixture.item(.caches, "com.apple.Example")
        try fixture.item(.applicationSupport, "CloudDocs")
        try fixture.item(.groupContainers, "group.com.apple.example")
        try FileManager.default.createDirectory(at: fixture.home.appendingPathComponent("Library/Mobile Documents/Example"),
                                                withIntermediateDirectories: true)
        let own = try fixture.item(.caches, "com.example.app")

        let items = try scanner(fixture).scan(app: app, otherApps: [])

        XCTAssertNotNil(item(items, fixture, own))
        XCTAssertFalse(items.contains { $0.url.path.lowercased().contains("com.apple.") })
        XCTAssertFalse(items.contains { $0.url.path.contains("Mobile Documents") || $0.url.lastPathComponent == "CloudDocs" })
        XCTAssertEqual(items.count, 2)
    }

    func testCrashReportsNamedAfterTheAppAreLikely() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try identity(fixture.app("Example", bundleID: "com.example.app"))
        let ips = try fixture.item(.diagnosticReports, "Example_2026-10-01-120000_Mac.ips", directory: false)
        let crash = try fixture.item(.diagnosticReports, "Example-2026-10-01.crash", directory: false)
        try fixture.item(.diagnosticReports, "Other_2026-10-01-120000_Mac.ips", directory: false)

        let items = try scanner(fixture).scan(app: app, otherApps: [])

        XCTAssertEqual(item(items, fixture, ips)?.confidence, .likely)
        XCTAssertEqual(item(items, fixture, ips)?.reason, "Crash report of Example.")
        XCTAssertEqual(item(items, fixture, ips)?.kind, .file)
        XCTAssertEqual(item(items, fixture, crash)?.confidence, .likely)
        XCTAssertFalse(items.contains { $0.url.lastPathComponent.hasPrefix("Other") })
    }

    func testWithoutFullDiskAccessContainersAreMarked() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try identity(fixture.app("Example", bundleID: "com.example.app"))
        let container = try fixture.item(.containers, "com.example.app")
        let cookies = try fixture.item(.cookies, "com.example.app.binarycookies", directory: false)
        let caches = try fixture.item(.caches, "com.example.app")

        let items = try scanner(fixture, hasFullDiskAccess: false).scan(app: app, otherApps: [])

        XCTAssertEqual(item(items, fixture, container)?.needsFullDiskAccess, true)
        XCTAssertEqual(item(items, fixture, cookies)?.needsFullDiskAccess, true)
        XCTAssertEqual(item(items, fixture, caches)?.needsFullDiskAccess, false)
    }

    func testAScanStopsWhenItsTaskIsCancelled() async throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try identity(fixture.app("Example", bundleID: "com.example.app"))
        try fixture.item(.caches, "com.example.app")
        let listed = Calls()
        var fileSystem = CleanerFileSystem.live
        let live = fileSystem.contents
        fileSystem.contents = { url in
            listed.record(url)
            withUnsafeCurrentTask { $0?.cancel() }
            return try live(url)
        }
        let scanner = scanner(fixture, fileSystem: fileSystem)

        let task = Task.detached { try scanner.scan(app: app, otherApps: []) }
        do {
            _ = try await task.value
            XCTFail("The scan finished although its task was cancelled.")
        } catch is CancellationError {}
        XCTAssertEqual(listed.all.count, 1)
    }

    func testAnUnreadableFolderIsSkipped() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try identity(fixture.app("Example", bundleID: "com.example.app"))
        let caches = try fixture.item(.caches, "com.example.app")
        let support = try fixture.item(.applicationSupport, "com.example.app")
        var fileSystem = CleanerFileSystem.live
        let live = fileSystem.contents
        fileSystem.contents = { url in
            if url.lastPathComponent == "Caches" { throw CocoaError(.fileReadNoPermission) }
            return try live(url)
        }

        let items = try scanner(fixture, fileSystem: fileSystem).scan(app: app, otherApps: [])

        XCTAssertNil(item(items, fixture, caches))
        XCTAssertNotNil(item(items, fixture, support))
    }

    func testARefusedBundleStopsTheScan() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let outside = fixture.home.appendingPathComponent("Documents", isDirectory: true)
        let app = try identity(fixture.app("Example", bundleID: "com.example.app", in: outside))
        XCTAssertThrowsError(try scanner(fixture).scan(app: app, otherApps: [])) { error in
            XCTAssertEqual(error as? FrogError, .message("This item is outside the folders Frog cleans."))
        }
    }

    func testFiveHundredEntriesScanQuickly() throws {
        let fixture = try CleanerFixture()
        defer { fixture.remove() }
        let app = try identity(fixture.app("Example", bundleID: "com.example.app"))
        for index in 0..<500 {
            try fixture.item(.caches, index.isMultiple(of: 2) ? "com.example.app.part\(index)" : "com.vendor\(index).tool",
                             directory: false)
        }
        let others = (0..<200).map {
            AppIdentity(path: "/Applications/App \($0).app", name: "App \($0)", bundleID: "com.vendor\($0).tool")
        }

        let start = Date()
        let items = try scanner(fixture).scan(app: app, otherApps: others)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(items.count, 251)
        // Measured at about 0.04 s in a debug build; the margin allows for a busy machine.
        XCTAssertLessThan(elapsed, 1.0)
    }
}
