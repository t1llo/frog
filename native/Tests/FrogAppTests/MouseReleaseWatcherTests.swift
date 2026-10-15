import XCTest
@testable import FrogApp

/// The one-shot release monitor, over a fake source: no real monitor and no timer.
final class MouseReleaseWatcherTests: XCTestCase {
    private final class FakeSource: MouseUpSource {
        var handlers: [Int: (CGPoint) -> Void] = [:]
        var added = 0
        var removed = 0
        var scheduled: [(work: DispatchWorkItem, delay: TimeInterval)] = []
        private var next = 0

        func addMonitor(_ handler: @escaping (CGPoint) -> Void) -> Any? {
            next += 1; added += 1
            handlers[next] = handler
            return next
        }

        func removeMonitor(_ monitor: Any) {
            removed += 1
            handlers[monitor as! Int] = nil
        }

        func schedule(_ work: DispatchWorkItem, after delay: TimeInterval) { scheduled.append((work, delay)) }

        func release(at point: CGPoint) { for handler in handlers.values { handler(point) } }
    }

    func testOneMonitorPerWatchAndTheReleaseCallsBackOnce() {
        let source = FakeSource()
        let watcher = MouseReleaseWatcher(source: source)
        var releases: [CGPoint] = []
        watcher.watch { _ in XCTFail("Replaced by the second call") }
        watcher.watch { releases.append($0) }
        XCTAssertEqual(source.added, 1)
        XCTAssertEqual(source.scheduled.count, 1)
        XCTAssertEqual(source.scheduled.first?.delay, 10)
        XCTAssertTrue(watcher.watching)

        source.release(at: CGPoint(x: 12, y: 34))
        XCTAssertEqual(releases, [CGPoint(x: 12, y: 34)])
        XCTAssertEqual(source.removed, 1)
        XCTAssertTrue(source.handlers.isEmpty)
        XCTAssertFalse(watcher.watching)
        XCTAssertEqual(source.scheduled.first?.work.isCancelled, true, "The timeout goes with the monitor")
        source.release(at: CGPoint(x: 1, y: 1))
        XCTAssertEqual(releases.count, 1)

        watcher.watch { releases.append($0) }
        XCTAssertEqual(source.added, 2)
        XCTAssertEqual(source.scheduled.count, 2)
    }

    func testCancelAndTheTimeoutRemoveTheMonitorWithoutCallingBack() {
        let source = FakeSource()
        let watcher = MouseReleaseWatcher(source: source, timeout: 3)
        watcher.watch { _ in XCTFail("Cancelled") }
        watcher.cancel()
        XCTAssertEqual(source.removed, 1)
        XCTAssertFalse(watcher.watching)
        source.release(at: .zero)

        watcher.watch { _ in XCTFail("Timed out") }
        XCTAssertEqual(source.scheduled.last?.delay, 3)
        source.scheduled.last?.work.perform()
        XCTAssertEqual(source.removed, 2)
        XCTAssertFalse(watcher.watching)
        source.release(at: .zero)
        XCTAssertEqual(source.scheduled.count, 2, "One single timeout per watch, never a repeating timer")
    }

    func testTheMonitorGoesWithTheWatcher() {
        let source = FakeSource()
        var watcher: MouseReleaseWatcher? = MouseReleaseWatcher(source: source)
        watcher?.watch { _ in }
        watcher = nil
        XCTAssertEqual(source.removed, 1)
        XCTAssertTrue(source.handlers.isEmpty)
    }
}
