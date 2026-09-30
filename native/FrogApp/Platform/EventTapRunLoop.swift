import Foundation

/// A blocking global event tap must never share the UI run loop: even unrelated
/// AppKit/IPC work would otherwise stall input in every application.
final class EventTapRunLoop: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var loop: CFRunLoop?
        var stopped = false
    }
    private let state = State()
    init(source: CFRunLoopSource, lifetime: AnyObject? = nil) {
        let state = self.state
        let thread = Thread {
            let loop = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(loop, source, .commonModes)
            state.lock.withLock { state.loop = loop }
            state.ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
            withExtendedLifetime(lifetime) {}
        }
        thread.name = "Frog keyboard input"
        thread.qualityOfService = .userInteractive
        thread.start()
        state.ready.wait()
    }
    func wakeUp() {
        if let loop = state.lock.withLock({ state.loop }) { CFRunLoopWakeUp(loop) }
    }
    func stop() {
        let loop: CFRunLoop? = state.lock.withLock {
            guard !state.stopped else { return nil }
            state.stopped = true
            return state.loop
        }
        guard let loop else { return }
        // A queued stop also handles teardown between ready.signal() and Run().
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
        CFRunLoopWakeUp(loop)
    }
    deinit { stop() }
}
