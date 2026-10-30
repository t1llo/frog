import AppKit
import ApplicationServices

/// How long Frog waits before it reads Accessibility and the login item again, and checks the
/// window switcher's event tap. A second while Frog is in front or Accessibility is still missing,
/// so a grant shows at once. Two seconds while the window switcher is on, because this tick is what
/// restarts its tap when macOS disables it. Otherwise it waits until Frog becomes active, the
/// Accessibility list changes, or a minute passes, so an idle Frog in the background wakes about
/// once a minute instead of every second.
@MainActor enum SystemStatusWake {
    static let idle: Duration = .seconds(60)
    static let tapCheck: Duration = .seconds(2)

    enum Pause: Equatable {
        case sleep(Duration)
        /// Until Frog becomes active, Accessibility changes or `idle` passes.
        case untilWake
    }

    /// Accessibility changed: `AXIsProcessTrusted()` can still give the old answer right when the
    /// notification arrives, so the next wait is a short one and the status is read once more.
    private static var readAgain = false

    static func pause(active: Bool, trusted: Bool, watchingTap: Bool, readAgain: Bool) -> Pause {
        if readAgain || active || !trusted { return .sleep(.seconds(1)) }
        if watchingTap { return .sleep(tapCheck) }
        return .untilWake
    }

    /// - Parameter watchingTap: the window switcher is on, so its tap needs a check every few seconds.
    static func wait(watchingTap: Bool = false) async throws {
        let again = readAgain
        readAgain = false
        switch pause(active: NSApp?.isActive == true, trusted: AXIsProcessTrusted(), watchingTap: watchingTap, readAgain: again) {
        case .sleep(let duration):
            try await Task.sleep(for: duration)
        case .untilWake:
            if try await accessibilityChanged() {
                // Read once a moment after the change, and once more on the next tick.
                readAgain = true
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Waits for the first wake; true when it was a change of the Accessibility list.
    private static func accessibilityChanged() async throws -> Bool {
        let wake = AsyncStream<Bool> { continuation in
            let local = NotificationCenter.default
            let distributed = DistributedNotificationCenter.default()
            let active = local.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                continuation.yield(false)
            }
            let accessibility = distributed.addObserver(forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
                continuation.yield(true)
            }
            let timeout = Task { try? await Task.sleep(for: idle, tolerance: .seconds(5)); continuation.yield(false) }
            continuation.onTermination = { _ in
                local.removeObserver(active)
                distributed.removeObserver(accessibility)
                timeout.cancel()
            }
        }
        var changed = false
        for await value in wake { changed = value; break }
        try Task.checkCancellation()
        return changed
    }
}
