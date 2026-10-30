import XCTest
import AppKit
@testable import FrogApp

/// The switcher's icon cache: drawn small, loaded off the main thread, bounded, emptied when the switcher stops.
@MainActor final class WindowSwitcherIconsTests: XCTestCase {
    nonisolated private static func icon() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            NSColor.systemGreen.setFill(); rect.fill(); return true
        }
    }

    private func load(_ icons: WindowSwitcherIcons, _ pids: [pid_t]) async -> [pid_t: NSImage] {
        await withCheckedContinuation { continuation in
            icons.request(pids) { continuation.resume(returning: $0) }
        }
    }

    func testIconsAreDrawnAtRowSizeWhateverTheirSource() async throws {
        let icons = WindowSwitcherIcons(load: { _ in Self.icon() })
        let loaded = await load(icons, [1])
        let bitmap = try XCTUnwrap(loaded[1]?.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(bitmap.pixelsWide, WindowSwitcherIcons.pixels)
        XCTAssertEqual(bitmap.pixelsHigh, WindowSwitcherIcons.pixels)
        XCTAssertEqual(loaded[1]?.size, NSSize(width: 20, height: 20))
        XCTAssertEqual(icons.byteCount, WindowSwitcherIcons.bytesPerIcon)
    }

    func testTheCacheKeepsTheMostRecentlyListedAppsUpToItsLimit() async {
        let icons = WindowSwitcherIcons(limit: 3, load: { _ in Self.icon() })
        _ = await load(icons, [1, 2, 3])
        // 1 is listed again, so 2 is now the oldest and goes first.
        _ = await load(icons, [4, 1])
        XCTAssertEqual(Set(icons.images.keys), [1, 3, 4])
        XCTAssertEqual(icons.byteCount, 3 * WindowSwitcherIcons.bytesPerIcon)
        icons.clear()
        XCTAssertTrue(icons.images.isEmpty)
        XCTAssertEqual(icons.byteCount, 0)
    }

    func testAnAppWithoutAnIconIsSkippedAndHeldIconsAreNotLoadedAgain() async {
        let calls = Calls()
        let icons = WindowSwitcherIcons(load: { pid in calls.add(pid); return pid == 2 ? nil : Self.icon() })
        let loaded = await load(icons, [1, 2])
        XCTAssertEqual(Set(loaded.keys), [1])
        _ = await load(icons, [1, 2])
        XCTAssertEqual(calls.values.filter { $0 == 1 }.count, 1, "An icon in the cache is not loaded twice")
    }

    /// What the default limit costs at most, printed with the measured cache for 30 windows of 12 apps.
    func testMemoryOfThirtyWindowsAndTheDefaultBound() async {
        let icons = WindowSwitcherIcons(load: { _ in Self.icon() })
        let pids = (0..<30).map { pid_t(100 + $0 % 12) }
        var seen = Set<pid_t>()
        _ = await load(icons, pids.filter { seen.insert($0).inserted })
        print("SWITCHER ICONS 30 windows of 12 apps: \(icons.images.count) icons, \(icons.byteCount) bytes; bound \(icons.limit) icons, \(icons.limit * WindowSwitcherIcons.bytesPerIcon) bytes")
        XCTAssertEqual(icons.images.count, 12)
        XCTAssertLessThanOrEqual(icons.limit * WindowSwitcherIcons.bytesPerIcon, 512 * 1024)
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [pid_t] = []
    func add(_ pid: pid_t) { lock.withLock { stored.append(pid) } }
    var values: [pid_t] { lock.withLock { stored } }
}
