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
        isCurrent: () -> Bool = { true },
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) }
    ) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
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
            AXUIElementSetMessagingTimeout(target.element, 0.1)
            var pid: pid_t = 0
            return AXUIElementGetPid(target.element, &pid) == .success && pid == target.pid
                && AXRead.string(target.element, kAXRoleAttribute) == kAXWindowRole
        }
        var isMinimized: @Sendable (WindowCatalog.Target) -> Bool = { AXRead.boolean($0.element, kAXMinimizedAttribute) == true }
        var unminimize: @Sendable (WindowCatalog.Target) -> Bool = {
            AXUIElementSetAttributeValue($0.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
        }
        var raise: @Sendable (WindowCatalog.Target) -> Bool = { AXUIElementPerformAction($0.element, kAXRaiseAction as CFString) == .success }
        var makeMain: @Sendable (WindowCatalog.Target) -> Void = {
            _ = AXUIElementSetAttributeValue($0.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        var bringForward: @Sendable (WindowCatalog.Target) -> Bool = { target in
            let app = AXUIElementCreateApplication(target.pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            return AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
        }
    }
    private let writer: Writer
    init(writer: Writer) { self.writer = writer }

    func raise(_ target: WindowCatalog.Target, isCurrent: @Sendable () -> Bool) -> Bool {
        func eligible() -> Bool { !Task.isCancelled && isCurrent() }
        guard eligible(), writer.isTrusted(), writer.isWindow(target), eligible() else { return false }
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
