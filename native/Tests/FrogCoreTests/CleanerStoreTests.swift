import XCTest
@testable import FrogCore

final class CleanerStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("frog-cleaner-store-\(UUID().uuidString)/Cleaner",
                                                                                   isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func record(_ title: String, date: Date) -> RemovalRecord {
        RemovalRecord(date: date, title: title, entries: [
            .init(original: "/Users/example/Library/Caches/\(title)", trashed: "/Users/example/.Trash/\(title)",
                  bytes: 10, route: .fileManager, owner: .user)
        ])
    }

    func testRecordsRoundTripNewestFirstAndOldOnesExpire() throws {
        let store = CleanerStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = record("Old", date: now.addingTimeInterval(-31 * 86_400))
        let older = record("Older", date: now.addingTimeInterval(-2 * 86_400))
        let newer = record("Newer", date: now.addingTimeInterval(-60))

        try store.add(older, now: now)
        try store.add(newer, now: now)
        try store.add(old, now: now.addingTimeInterval(-86_400 * 2))

        XCTAssertEqual(try store.records(now: now), [newer, older])
        XCTAssertEqual(try CleanerStore(directory: directory).records(now: now), [newer, older])

        var changed = older
        changed.entries[0].restored = true
        try store.replace(changed)
        XCTAssertEqual(try store.records(now: now), [newer, changed])
        try store.delete(id: newer.id)
        XCTAssertEqual(try store.records(now: now), [changed])
        // A month later the last one expires and leaves the file.
        XCTAssertEqual(try store.records(now: now.addingTimeInterval(30 * 86_400)), [])
        XCTAssertEqual(try store.records(now: now), [])
    }

    func testAtMostAHundredRecordsAreKept() throws {
        let store = CleanerStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<105 {
            try store.add(record("Item \(index)", date: now.addingTimeInterval(Double(index - 105))), now: now)
        }
        let records = try store.records(now: now)
        XCTAssertEqual(records.count, 100)
        XCTAssertEqual(records.first?.title, "Item 104")
        XCTAssertEqual(records.last?.title, "Item 5")
    }

    func testAnUnreadableFileIsSetAsideAndRemovalsGoOn() throws {
        let store = CleanerStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("removals.json"))

        XCTAssertEqual(try store.records(), [])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let aside = names.filter { $0.hasPrefix("removals-unreadable-") && $0.hasSuffix(".json") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(aside[0])), Data("not json".utf8))

        let saved = record("Example", date: Date())
        try store.add(saved)
        XCTAssertEqual(try store.records(), [saved])
    }

    func testFlagsPersistOnThisMac() throws {
        let store = CleanerStore(directory: directory)
        XCTAssertFalse(store.flag("removedAppNoticeDismissed"))
        try store.setFlag("removedAppNoticeDismissed", true)
        XCTAssertTrue(CleanerStore(directory: directory).flag("removedAppNoticeDismissed"))
        XCTAssertFalse(store.flag("other"))
        try store.setFlag("removedAppNoticeDismissed", false)
        XCTAssertFalse(CleanerStore(directory: directory).flag("removedAppNoticeDismissed"))
    }

    func testFilesArePrivate() throws {
        let store = CleanerStore(directory: directory)
        try store.add(record("Example", date: Date()))
        try store.setFlag("seen", true)
        for name in ["removals.json", "state.json"] {
            let path = directory.appendingPathComponent(name).path
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
