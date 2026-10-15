import Foundation
import FrogCore
@testable import FrogApp

/// Windows that behave like an app's, without any real window: writes are recorded in order
/// and change the stored frame the way an app would, keeping to a minimum size.
final class FixtureWindowAccess: WindowAccess, @unchecked Sendable {
    struct Window {
        /// nil when the app does not report a frame.
        var frame: CGRect?
        var state = WindowState()
        var minimumSize: CGSize?
        /// The app reports the position as settable but rejects the write.
        var refusesPosition = false
        /// The app reports the size as settable but rejects the write.
        var refusesSize = false
    }

    enum Write: Equatable {
        case position(WindowKey, CGPoint)
        case size(WindowKey, CGSize)
        case minimized(WindowKey, Bool)
        case fullScreen(WindowKey, Bool)
    }

    private struct Storage {
        var windows: [WindowKey: Window] = [:]
        var focused: [pid_t: WindowKey] = [:]
        var trusted = true
        var writes: [Write] = []
        var delay: [pid_t: Duration] = [:]
    }

    static let failure = FrogError.message("macOS could not apply this window action. The app may not support it.")
    private let lock = NSLock()
    private var storage = Storage()

    private func locked<T>(_ body: (inout Storage) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&storage)
    }

    var windows: [WindowKey: Window] {
        get { locked { $0.windows } }
        set { locked { $0.windows = newValue } }
    }
    var focused: [pid_t: WindowKey] {
        get { locked { $0.focused } }
        set { locked { $0.focused = newValue } }
    }
    var trusted: Bool {
        get { locked { $0.trusted } }
        set { locked { $0.trusted = newValue } }
    }
    var writes: [Write] {
        get { locked { $0.writes } }
        set { locked { $0.writes = newValue } }
    }
    /// How long the app with this pid takes to apply a frame.
    var delay: [pid_t: Duration] {
        get { locked { $0.delay } }
        set { locked { $0.delay = newValue } }
    }

    /// Adds a window and makes it the focused window of its app.
    @discardableResult
    func add(_ key: WindowKey, frame: CGRect?, state: WindowState = WindowState(), minimumSize: CGSize? = nil) -> WindowKey {
        locked {
            $0.windows[key] = Window(frame: frame, state: state, minimumSize: minimumSize)
            $0.focused[key.pid] = key
        }
        return key
    }

    func isTrusted() -> Bool { trusted }

    func focusedWindow(pid: pid_t) -> WindowHandle? {
        locked { storage in
            guard let key = storage.focused[pid], storage.windows[key] != nil else { return nil }
            return WindowHandle(key: key, element: nil)
        }
    }

    func frame(of window: WindowHandle) -> CGRect? { locked { $0.windows[window.key]?.frame } }

    func state(of window: WindowHandle) -> WindowState { locked { $0.windows[window.key]?.state ?? WindowState() } }

    func setFrame(_ frame: CGRect, of window: WindowHandle, resize: Bool) throws {
        if let delay = delay[window.key.pid] {
            let parts = delay.components
            Thread.sleep(forTimeInterval: Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        }
        try locked { storage in
            guard var stored = storage.windows[window.key] else { throw Self.failure }
            func position() throws {
                guard !stored.refusesPosition else { throw Self.failure }
                storage.writes.append(.position(window.key, frame.origin))
                stored.frame = CGRect(origin: frame.origin, size: stored.frame?.size ?? frame.size)
            }
            defer { storage.windows[window.key] = stored }
            try position()
            if resize {
                guard !stored.refusesSize else { throw Self.failure }
                var size = frame.size
                if let minimum = stored.minimumSize {
                    size = CGSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height))
                }
                storage.writes.append(.size(window.key, size))
                stored.frame = CGRect(origin: stored.frame?.origin ?? frame.origin, size: size)
            }
            try position()
        }
    }

    func setMinimized(_ minimized: Bool, of window: WindowHandle) throws {
        try locked { storage in
            guard storage.windows[window.key] != nil else { throw Self.failure }
            storage.writes.append(.minimized(window.key, minimized))
            storage.windows[window.key]?.state.minimized = minimized
        }
    }

    func setFullScreen(_ fullScreen: Bool, of window: WindowHandle) throws {
        try locked { storage in
            guard storage.windows[window.key] != nil else { throw Self.failure }
            storage.writes.append(.fullScreen(window.key, fullScreen))
            storage.windows[window.key]?.state.fullScreen = fullScreen
        }
    }
}
