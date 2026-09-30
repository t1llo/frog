import Foundation
import CoreGraphics

/// Synchronous input decisions only. No AppKit, AX, UI work, or main-queue waits.
/// The short lock also lets UI completion retire an exact session/activation.
final class WindowSwitchInput: @unchecked Sendable {
    enum Event: Sendable {
        case key(WindowSwitchKeyRouter.Result, cancelActivation: UUID?)
        case mouse(CGPoint, session: UInt64?, activation: UUID?)
        case reset(session: UInt64?)
    }
    private let lock = NSLock()
    private var router = WindowSwitchKeyRouter()
    private var activation: UUID?
    private var lastKeyDown: ContinuousClock.Instant?
    private var stopped = false
    private var tap: CFMachPort?
    private let send: @Sendable (Event) -> Void

    init(send: @escaping @Sendable (Event) -> Void) { self.send = send }
    var state: WindowSwitchKeyRouter { lock.withLock { router } }
    func attach(_ tap: CFMachPort) { lock.withLock { self.tap = tap } }
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
    func stop() { lock.withLock { stopped = true; router.reset(); activation = nil; tap = nil } }

    func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let result = lock.withLock { () -> (consume: Bool, message: Event?, enable: CFMachPort?) in
            guard !stopped else { return (false, nil, nil) }
            if type == .keyDown { lastKeyDown = .now }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                let session = router.sessionID; router.reset()
                return (false, .reset(session: session), tap)
            }
            if type == .leftMouseDown || type == .rightMouseDown {
                guard router.sessionID != nil || activation != nil else { return (false, nil, nil) }
                return (false, .mouse(event.location, session: router.sessionID, activation: activation), nil)
            }
            let result: WindowSwitchKeyRouter.Result
            if type == .flagsChanged { result = router.modifiers(command: event.flags.contains(.maskCommand)) }
            else if type == .keyDown || type == .keyUp {
                let command = event.flags.contains(.maskCommand)
                let other = !event.flags.intersection([.maskControl, .maskAlternate]).isEmpty
                // Ordinary typing never needs a keyboard-layout/IME lookup.
                let text = type == .keyDown && router.active && command && !other ? Self.text(event) : ""
                result = router.key(code: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), down: type == .keyDown,
                                    command: command, shift: event.flags.contains(.maskShift), otherModifiers: other, text: text)
            } else { return (false, nil, nil) }
            let cancelled = type == .keyDown && result.cancelsPendingActivation ? activation : nil
            if cancelled != nil { activation = nil }
            guard result.action != nil || cancelled != nil else { return (result.consume, nil, nil) }
            return (result.consume, .key(result, cancelActivation: cancelled), nil)
        }
        if let tap = result.enable { CGEvent.tapEnable(tap: tap, enable: true) }
        if let message = result.message { send(message) }
        return result.consume ? nil : Unmanaged.passUnretained(event)
    }

    private static func text(_ event: CGEvent) -> String {
        var units = [UniChar](repeating: 0, count: 32), count = 0
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
        return String(utf16CodeUnits: units, count: min(count, units.count))
    }
}
