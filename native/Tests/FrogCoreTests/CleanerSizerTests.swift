import XCTest
import Darwin
@testable import FrogCore

final class CleanerSizerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("frog-sizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func file(_ relative: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Random bytes, so APFS cannot store the file sparsely or compressed.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: url)
        return url
    }

    private func allocated(_ url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        return Int64(info.st_blocks) * 512
    }

    /// What `du` would add up: every entry below `url`, links not followed.
    private func allocatedTree(_ url: URL) -> Int64 {
        var total = allocated(url)
        let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [])
        while let entry = entries?.nextObject() as? URL { total += allocated(entry) }
        return total
    }

    func testAllocatedSizeCountsEveryFileInsideAFolder() throws {
        try file("Item/a", bytes: 10_000)
        try file("Item/Nested/b", bytes: 70_000)
        try file("Item/Nested/Deeper/c", bytes: 1)
        let item = root.appendingPathComponent("Item")

        let size = CleanerSizer().measure(item)

        XCTAssertTrue(size.complete)
        XCTAssertGreaterThanOrEqual(size.bytes, 80_000)
        XCTAssertEqual(size.bytes, allocatedTree(item))
        XCTAssertNil(size.newest)
    }

    func testAHardLinkedFileCountsOnceAcrossItems() throws {
        let original = try file("First/shared", bytes: 200_000)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Second"), withIntermediateDirectories: true)
        XCTAssertEqual(link(original.path, root.appendingPathComponent("Second/shared").path), 0)
        let first = root.appendingPathComponent("First"), second = root.appendingPathComponent("Second")

        let sizes = CleanerSizer().measure([first, second])
        let alone = CleanerSizer().measure(second)

        XCTAssertEqual(sizes[first.path]?.bytes, allocated(first) + allocated(original))
        XCTAssertEqual(sizes[second.path]?.bytes, allocated(second))
        XCTAssertEqual(alone.bytes, allocated(second) + allocated(original))
        XCTAssertEqual(sizes[first.path]?.complete, true)
    }

    func testALinkIsCountedAsALinkAndNotFollowed() throws {
        let large = try file("Elsewhere/large", bytes: 2_000_000)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Item"), withIntermediateDirectories: true)
        let inside = root.appendingPathComponent("Item/link")
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: large)
        let folderLink = root.appendingPathComponent("FolderLink")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: large.deletingLastPathComponent())
        let item = root.appendingPathComponent("Item")

        let sizes = CleanerSizer().measure([item, inside, folderLink])

        XCTAssertEqual(sizes[item.path]?.bytes, allocated(item) + allocated(inside))
        XCTAssertLessThan(sizes[item.path]?.bytes ?? .max, allocated(large))
        XCTAssertEqual(sizes[inside.path]?.bytes, allocated(inside))
        XCTAssertEqual(sizes[folderLink.path]?.bytes, allocated(folderLink))
        XCTAssertEqual(sizes[folderLink.path]?.complete, true)
    }

    func testAnUnreadableFolderMakesTheSizeIncomplete() throws {
        try file("Item/readable", bytes: 5_000)
        let locked = try file("Item/Locked/secret", bytes: 5_000).deletingLastPathComponent()
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { chmod(locked.path, 0o755) }

        let size = CleanerSizer().measure(root.appendingPathComponent("Item"))

        XCTAssertFalse(size.complete)
        XCTAssertGreaterThanOrEqual(size.bytes, 5_000)
    }

    func testAMissingItemHasNoCompleteSize() {
        let size = CleanerSizer().measure(root.appendingPathComponent("Missing"))
        XCTAssertEqual(size, CleanerSize(bytes: 0, complete: false))
    }

    func testCancellationReturnsAnIncompleteSize() async throws {
        let item = root.appendingPathComponent("Item")
        try file("Item/a", bytes: 5_000)
        let sizes = await Task.detached(priority: .utility) {
            withUnsafeCurrentTask { $0?.cancel() }
            return CleanerSizer().measure([item, item.appendingPathComponent("a")])
        }.value

        XCTAssertEqual(sizes[item.path], CleanerSize(bytes: 0, complete: false))
        XCTAssertEqual(sizes[item.appendingPathComponent("a").path]?.complete, false)
    }

    func testTheEntryLimitStopsTheWalkWithAnIncompleteSize() throws {
        for index in 0..<5 { try file("Item/\(index)", bytes: 1_000) }
        let item = root.appendingPathComponent("Item")

        XCTAssertFalse(CleanerSizer(maximumEntries: 3).measure(item).complete)
        XCTAssertTrue(CleanerSizer(maximumEntries: 6).measure(item).complete)
    }

    func testNewestModificationCoversTheWholeSubtree() throws {
        let fresh = try file("Old/Inner/fresh", bytes: 100)
        let old = Date().addingTimeInterval(-60 * 86_400)
        let inner = fresh.deletingLastPathComponent(), outer = inner.deletingLastPathComponent()
        for folder in [inner, outer] {
            var times = [timeval(tv_sec: Int(old.timeIntervalSince1970), tv_usec: 0),
                         timeval(tv_sec: Int(old.timeIntervalSince1970), tv_usec: 0)]
            XCTAssertEqual(utimes(folder.path, &times), 0)
        }

        let dated = CleanerSizer().measure(outer, includeDates: true)
        let undated = CleanerSizer().measure(outer)

        XCTAssertEqual(dated.newest?.timeIntervalSinceNow ?? -.infinity, 0, accuracy: 60)
        XCTAssertNil(undated.newest)
        let folderDate = try outer.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(folderDate?.timeIntervalSince1970 ?? 0, old.timeIntervalSince1970, accuracy: 1)
    }

    func testADatalessFileIsSkippedButItsDateCounts() throws {
        let placeholder = try file("Item/placeholder", bytes: 50_000)
        try file("Item/local", bytes: 5_000)
        let placeholderPath = placeholder.path
        let sizer = CleanerSizer(maximumEntries: 100, entryFlags: { path, flags in
            path == placeholderPath ? flags | CleanerSizer.datalessFlag : flags
        }, contentIdentifier: { _ in nil })
        let item = root.appendingPathComponent("Item")

        let size = sizer.measure(item, includeDates: true)

        XCTAssertFalse(size.complete)
        XCTAssertEqual(size.bytes, allocatedTree(item) - allocated(placeholder))
        XCTAssertNotNil(size.newest)
    }

    func testADatalessFolderIsNotEntered() throws {
        let cloud = try file("Item/Cloud/inside", bytes: 50_000).deletingLastPathComponent()
        let cloudPath = cloud.path
        let sizer = CleanerSizer(maximumEntries: 100, entryFlags: { path, flags in
            path == cloudPath ? flags | CleanerSizer.datalessFlag : flags
        }, contentIdentifier: { _ in nil })
        let item = root.appendingPathComponent("Item")

        let size = sizer.measure(item)

        XCTAssertFalse(size.complete)
        XCTAssertEqual(size.bytes, allocated(item))
    }

    func testClonesOfALargeFileCountOnce() throws {
        let first = try file("Item/first", bytes: 1_100_000)
        let second = try file("Item/second", bytes: 1_100_000)
        try file("Item/small", bytes: 1_000)
        let sizer = CleanerSizer(maximumEntries: 100, entryFlags: { $1 }, contentIdentifier: { _ in 42 })
        let item = root.appendingPathComponent("Item")

        let size = sizer.measure(item)

        XCTAssertTrue(size.complete)
        XCTAssertEqual(size.bytes, allocatedTree(item) - allocated(second))
        XCTAssertEqual(allocated(first), allocated(second))
    }

    func testThePolicyKeepsPlaceholdersOnTheServerAndIsRestored() throws {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let original = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        XCTAssertGreaterThanOrEqual(original, 0)
        defer { setiopolicy_np(type, IOPOL_SCOPE_THREAD, original) }
        XCTAssertEqual(setiopolicy_np(type, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_ON), 0)

        let inside = CleanerIOPolicy.withoutDownloading { getiopolicy_np(type, IOPOL_SCOPE_THREAD) }
        XCTAssertEqual(inside, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        XCTAssertEqual(getiopolicy_np(type, IOPOL_SCOPE_THREAD), IOPOL_MATERIALIZE_DATALESS_FILES_ON)

        _ = CleanerSizer().measure(root)
        XCTAssertEqual(getiopolicy_np(type, IOPOL_SCOPE_THREAD), IOPOL_MATERIALIZE_DATALESS_FILES_ON)
    }
}
