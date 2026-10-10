import AppKit
import ApplicationServices

/// The switcher's explicit user selection, isolated from native AX/activation calls.
@MainActor
enum WindowActivation {
    static func perform(
        raise: () async -> Bool,
        request: () -> Bool,
        bringForward: () async -> Bool,
        isFrontmost: () -> Bool,
        prepare: (() async -> Bool)? = nil,
        isCurrent: () -> Bool = { true },
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) }
    ) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        if let prepare {
            guard await prepare(), !Task.isCancelled, isCurrent() else { return false }
        }
        // Start the OS transition immediately, overlapping it with the selected
        // window's AX work. A same-app selection needs no activation request.
        let requested = isFrontmost() ? true : request()
        guard !Task.isCancelled, isCurrent() else { return false }
        let raisedInFront = isFrontmost()
        guard await raise(), !Task.isCancelled, isCurrent() else { return false }
        if raisedInFront { return isFrontmost() }
        if !isFrontmost() {
            // Activation is a request, not proof of foreground ownership. A
            // switcher action is explicit user intent, so use the public AX
            // frontmost attribute if the other application still owns focus.
            if !isFrontmost() {
                let forwarded = await bringForward()
                guard !Task.isCancelled, isCurrent(), requested || forwarded else { return false }
            }
            for _ in 0..<15 {
                guard !Task.isCancelled, isCurrent() else { return false }
                if isFrontmost() { break }
                do { try await pause() } catch { return false }
            }
        }
        guard !Task.isCancelled, isCurrent(), isFrontmost(), await raise(), !Task.isCancelled, isCurrent() else { return false }
        return isFrontmost()
    }
}

/// Serializes focus-changing AX calls independently of inventory reads. Cancellation
/// is checked after every potentially blocking read and before every side effect.
actor WindowActivationExecutor {
    struct Writer: Sendable {
        var isTrusted: @Sendable () -> Bool = { AXIsProcessTrusted() }
        var isWindow: @Sendable (WindowCatalog.Target) -> Bool = { target in
            guard let element = target.element else { return false }
            AXUIElementSetMessagingTimeout(element, 0.1)
            var pid: pid_t = 0
            return AXUIElementGetPid(element, &pid) == .success && pid == target.pid
                && (target.windowID.map { WindowSpaceBridge.windowID(element) == $0 } ?? true)
                && AXRead.string(element, kAXRoleAttribute) == kAXWindowRole
        }
        var isMinimized: @Sendable (WindowCatalog.Target) -> Bool = { $0.element.map { AXRead.boolean($0, kAXMinimizedAttribute) == true } ?? false }
        var unminimize: @Sendable (WindowCatalog.Target) -> Bool = {
            guard let element = $0.element else { return false }
            return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
        }
        var raise: @Sendable (WindowCatalog.Target) -> Bool = {
            guard let element = $0.element else { return false }
            return AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
        }
        var makeMain: @Sendable (WindowCatalog.Target) -> Void = {
            guard let element = $0.element else { return }
            _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        var bringForward: @Sendable (WindowCatalog.Target) -> Bool = { target in
            let app = AXUIElementCreateApplication(target.pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            return AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
        }
        var reveal: @Sendable (WindowCatalog.Target, @Sendable () -> Bool, @Sendable () async -> Void) async -> Bool = { target, current, willChange in
            guard let id = target.windowID else { return target.element != nil }
            return await WindowSpaceBridge.reveal(id, pid: target.pid, isCurrent: current, willChangeSpace: willChange)
        }
        var resolve: @Sendable (CGWindowID, pid_t) -> AXUIElement? = { WindowSpaceBridge.resolve($0, pid: $1) }
    }
    private let writer: Writer
    private var prepared: WindowCatalog.Target?
    init(writer: Writer) { self.writer = writer }

    func prepare(_ target: WindowCatalog.Target, isCurrent: @escaping @Sendable () -> Bool,
                 willChangeSpace: @escaping @Sendable () async -> Void = {}) async -> Bool {
        guard !Task.isCancelled, isCurrent(), writer.isTrusted(),
              await writer.reveal(target, isCurrent, willChangeSpace), !Task.isCancelled, isCurrent() else { return false }
        var element = target.element
        if element == nil, let windowID = target.windowID {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            repeat {
                guard !Task.isCancelled, isCurrent() else { return false }
                element = writer.resolve(windowID, target.pid)
                if element != nil { break }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
            } while ContinuousClock.now < deadline
        }
        guard !Task.isCancelled, isCurrent(), let element else { return false }
        prepared = WindowCatalog.Target(id: target.id, pid: target.pid, element: element, windowID: target.windowID)
        return true
    }

    func raise(_ target: WindowCatalog.Target, isCurrent: @escaping @Sendable () -> Bool) async -> Bool {
        func eligible() -> Bool { !Task.isCancelled && isCurrent() }
        guard eligible() else { return false }
        // Command-bar callers also get remote-window preparation even if they do
        // not have a separate application activation phase.
        if target.windowID != nil, prepared?.id != target.id, !(await prepare(target, isCurrent: isCurrent)) { return false }
        var target = prepared?.id == target.id ? prepared! : target
        if prepared?.id == target.id { prepared = nil }
        guard eligible(), writer.isTrusted() else { return false }
        if !writer.isWindow(target) {
            // Some owners replace their AX element when its Space becomes
            // visible. Re-resolve the exact native ID rather than raising a
            // stale reference or falling back to an arbitrary app window.
            guard eligible(), let id = target.windowID, let element = writer.resolve(id, target.pid), eligible() else { return false }
            target = WindowCatalog.Target(id: target.id, pid: target.pid, element: element, windowID: id)
            guard writer.isWindow(target), eligible() else { return false }
        }
        guard eligible() else { return false }
        let minimized = writer.isMinimized(target)
        guard eligible() else { return false }
        if minimized {
            guard writer.unminimize(target), eligible() else { return false }
        }
        guard writer.raise(target), eligible() else { return false }
        writer.makeMain(target)
        return eligible()
    }

    func bringForward(_ target: WindowCatalog.Target, isCurrent: @Sendable () -> Bool) -> Bool {
        guard !Task.isCancelled, isCurrent(), writer.isTrusted() else { return false }
        return writer.bringForward(target)
    }
}
