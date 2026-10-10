import Foundation
import CoreGraphics
import FrogCore

/// Synchronous input decisions only. No AppKit, AX, UI work, or main-queue waits.
/// The short lock also lets UI completion retire an exact session/activation.
final class WindowSwitchInput: @unchecked Sendable {
    enum Event: Sendable {
        case key(WindowSwitchKeyRouter.Result, cancelActivation: UUID?)
        case mouse(CGPoint, session: UInt64?, activation: UUID?)
        case reset(session: UInt64?, activation: UUID?)
    }
    private let lock = NSLock()
    private var router: WindowSwitchKeyRouter
    private var activation: UUID?
    private var lastKeyDown: ContinuousClock.Instant?
    private var stopped = false
    private var reenableTap: (@Sendable () -> Void)?
    private let send: @Sendable (Event) -> Void

    init(hotkey: Hotkey = WindowSwitchKeyRouter.defaultHotkey,
         reenableTap: (@Sendable () -> Void)? = nil, send: @escaping @Sendable (Event) -> Void) {
        router = WindowSwitchKeyRouter(hotkey: hotkey)
        self.reenableTap = reenableTap; self.send = send
    }
    var state: WindowSwitchKeyRouter { lock.withLock { router } }
    func attach(_ tap: CFMachPort) {
        lock.withLock {
            guard !stopped else { return }
            reenableTap = { if CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: true) } }
        }
    }
    @discardableResult
    func finish(session: UInt64, activating id: UUID? = nil) -> Bool {
        lock.withLock {
            guard router.sessionID == session else { return false }
            // No gap where newly typed input could miss both session and activation.
            router.finish(session: session)
            if let id { activation = id }
            return true
        }
    }
    func cancelActivation(_ id: UUID?) { lock.withLock { if activation == id { activation = nil } } }
    func isActivationPending(_ id: UUID) -> Bool { lock.withLock { activation == id } }
    func shouldDeferBackgroundWork(at now: ContinuousClock.Instant = .now) -> Bool {
        lock.withLock { lastKeyDown.map { $0.duration(to: now) < .seconds(1) } ?? false }
    }
    func stop() { lock.withLock { stopped = true; router.reset(); activation = nil; reenableTap = nil } }

    func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let result = lock.withLock { () -> (consume: Bool, message: Event?) in
            guard !stopped else { return (false, nil) }
            if type == .keyDown { lastKeyDown = .now }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                let session = router.sessionID, cancelled = activation
                router.reset(); activation = nil
                // stop() clears cached eligibility under this same lock. There
                // must be no trailing re-enable after the owner retires the tap.
                // This closure performs only the bounded CoreGraphics operation.
                reenableTap?()
                return (false, .reset(session: session, activation: cancelled))
            }
            if type == .leftMouseDown || type == .rightMouseDown {
                guard router.sessionID != nil || activation != nil else { return (false, nil) }
                // Activation only exists after the overlay session is retired;
                // every click then invalidates it without waiting for the UI queue.
                // Active-overlay hit testing still belongs to the controller.
                let cancelled = activation
                activation = nil
                return (false, .mouse(event.location, session: router.sessionID, activation: cancelled))
            }
            let result: WindowSwitchKeyRouter.Result
            if type == .flagsChanged { result = router.modifiers(flags: event.flags) }
            else if type == .keyDown || type == .keyUp {
                // Ordinary typing never needs a keyboard-layout/IME lookup.
                let text = type == .keyDown && router.acceptsSearch(flags: event.flags) ? Self.text(event) : ""
                result = router.key(code: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), down: type == .keyDown,
                                    flags: event.flags, text: text)
            } else { return (false, nil) }
            let cancelled = type == .keyDown && result.cancelsPendingActivation ? activation : nil
            if cancelled != nil { activation = nil }
            guard result.action != nil || cancelled != nil else { return (result.consume, nil) }
            return (result.consume, .key(result, cancelActivation: cancelled))
        }
        if let message = result.message { send(message) }
        return result.consume ? nil : Unmanaged.passUnretained(event)
    }

    private static func text(_ event: CGEvent) -> String {
        var units = [UniChar](repeating: 0, count: 32), count = 0
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
        return String(utf16CodeUnits: units, count: min(count, units.count))
    }
}
