import XCTest
@testable import FrogApp

@MainActor
final class EventTapRunLoopTests: XCTestCase {
    func testImmediateRepeatedStopReleasesTheCallbackOwnerOffMain() throws {
        for _ in 0..<20 {
            let released = DispatchSemaphore(value: 0)
            var context = CFRunLoopSourceContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil,
                                                equal: nil, hash: nil, schedule: nil, cancel: nil, perform: { _ in })
            let source = try XCTUnwrap(CFRunLoopSourceCreate(nil, 0, &context))
            var input: EventTapRunLoop? = EventTapRunLoop(source: source, lifetime: CallbackLifetime { released.signal() })
            input?.stop(); input?.stop(); input = nil
            XCTAssertEqual(released.wait(timeout: .now() + .milliseconds(200)), .success)
        }
    }

    func testGlobalInputDeliveryDoesNotWaitForTheMainThread() throws {
        let delivered = DispatchSemaphore(value: 0)
        var context = CFRunLoopSourceContext(version: 0, info: Unmanaged.passUnretained(delivered).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil, equal: nil, hash: nil,
                                            schedule: nil, cancel: nil, perform: { pointer in
            guard let pointer else { return }
            Unmanaged<DispatchSemaphore>.fromOpaque(pointer).takeUnretainedValue().signal()
        })
        let source = try XCTUnwrap(CFRunLoopSourceCreate(nil, 0, &context))
        let input = EventTapRunLoop(source: source, lifetime: delivered)
        defer { input.stop() }
        DispatchQueue.global(qos: .userInitiated).async {
            CFRunLoopSourceSignal(source); input.wakeUp()
        }
        // Model a synchronous AppKit/IPC stall. A keyboard tap must respond while
        // the UI thread is unavailable, or typing in every other app stalls too.
        XCTAssertEqual(delivered.wait(timeout: .now() + .milliseconds(200)), .success)
    }
}

private final class CallbackLifetime: @unchecked Sendable {
    let release: @Sendable () -> Void
    init(release: @escaping @Sendable () -> Void) { self.release = release }
    deinit { release() }
}
