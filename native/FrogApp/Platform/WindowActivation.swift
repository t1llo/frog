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
        /// An app asked for earlier is still on its way, so being reported in front is stale.
        expectsAnother: () -> Bool = { false },
        prepare: (() async -> Bool)? = nil,
        isCurrent: () -> Bool = { true },
        /// The first raise once the app was asked to come forward, which no longer stops
        /// for `isCurrent` or cancellation: input arriving after the request does not keep
        /// the app away, so it must not keep the chosen window away. Later steps still stop.
        raiseAfterRequest: (() async -> Bool)? = nil,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) }
    ) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        if let prepare {
            guard await prepare(), !Task.isCancelled, isCurrent() else { return false }
        }
        // Start the OS transition immediately, overlapping it with the selected
        // window's AX work. A same-app selection needs no activation request,
        // unless the app must follow another one that has yet to arrive.
        let asks = !isFrontmost() || expectsAnother()
        let requested = asks ? request() : true
        let committed = asks && requested ? raiseAfterRequest : nil
        if committed == nil { guard !Task.isCancelled, isCurrent() else { return false } }
        let raisedInFront = isFrontmost()
        let raised: Bool
        if let committed { raised = await committed() } else { raised = await raise() }
        guard raised, !Task.isCancelled, isCurrent() else { return false }
        if raisedInFront { return isFrontmost() }
        if !isFrontmost() {
            // Activation is a request, not proof of foreground ownership. A
            // switcher action is explicit user intent, so use the public AX
            // frontmost attribute if the other application still owns focus.
            let forwarded = await bringForward()
            guard !Task.isCancelled, isCurrent(), requested || forwarded else { return false }
            for _ in 0..<15 {
                guard !Task.isCancelled, isCurrent() else { return false }
                if isFrontmost() { break }
                do { try await pause() } catch { return false }
            }
        }
        guard !Task.isCancelled, isCurrent(), isFrontmost() else { return false }
        // The window was raised already. Raising it again keeps the app's own arrival from
        // covering it; an app slow to answer that does not undo a switch that went through.
        _ = await raise()
        guard !Task.isCancelled, isCurrent() else { return false }
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
        /// `.cannotComplete` is a raise its owner did not answer in time, which may still arrive.
        var raise: @Sendable (WindowCatalog.Target) -> AXError = {
            guard let element = $0.element else { return .invalidUIElement }
            return AXUIElementPerformAction(element, kAXRaiseAction as CFString)
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
    private let now: @Sendable () -> ContinuousClock.Instant
    private var prepared: WindowCatalog.Target?
    /// The window raised last, for a moment: raising it again once its app is in front finds it
    /// on the Desktop in sight, so its Desktop is not looked for again. Any other step ends it.
    private var raisedLast: (target: WindowCatalog.Target, until: ContinuousClock.Instant)?
    init(writer: Writer, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) { self.writer = writer; self.now = now }

    func prepare(_ target: WindowCatalog.Target, isCurrent: @escaping @Sendable () -> Bool,
                 willChangeSpace: @escaping @Sendable () async -> Void = {}) async -> Bool {
        raisedLast = nil
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

    /// `requested`: the window's app was asked to come forward already and arrives whatever
    /// input follows. The window prepared for that request is then raised all the same, so the
    /// app does not arrive showing another one; a window that was not prepared still stops.
    func raise(_ target: WindowCatalog.Target, isCurrent: @escaping @Sendable () -> Bool, requested: Bool = false) async -> Bool {
        let finishing = requested && prepared?.id == target.id
        func eligible() -> Bool { finishing || (!Task.isCancelled && isCurrent()) }
        let again = raisedLast.flatMap { $0.target.id == target.id && now() < $0.until ? $0.target : nil }
        raisedLast = nil
        guard eligible() else { return false }
        // Command-bar callers also get remote-window preparation even if they do
        // not have a separate application activation phase.
        if again == nil, target.windowID != nil, prepared?.id != target.id, !(await prepare(target, isCurrent: isCurrent)) { return false }
        var target = again ?? (prepared?.id == target.id ? prepared! : target)
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
        var raised = writer.raise(target)
        // Restoring animates, and its owner may not answer until the window is back. Any
        // other owner that has not answered yet, busy unhiding say, gets the same wait;
        // a window that refuses or is gone is not raised again.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while raised != .success, minimized || raised == .cannotComplete, eligible(), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return false }
            raised = writer.raise(target)
        }
        guard raised == .success, eligible() else { return false }
        writer.makeMain(target)
        guard eligible() else { return false }
        // Once: a raise that skipped the lookup is no reason to skip the next one.
        if again == nil { raisedLast = (target, now().advanced(by: .seconds(2))) }
        return true
    }

    func bringForward(_ target: WindowCatalog.Target, isCurrent: @Sendable () -> Bool) -> Bool {
        guard !Task.isCancelled, isCurrent(), writer.isTrusted() else { return false }
        return writer.bringForward(target)
    }
}
