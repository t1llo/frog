import AppKit
import ApplicationServices

/// How long Frog waits before it reads Accessibility and the login item again. A second while Frog
/// is in front or Accessibility is still missing, so a grant shows at once. Otherwise it waits until
/// Frog becomes active, the Accessibility list changes, or a minute passes, so an idle Frog in the
/// background wakes about once a minute instead of every second.
@MainActor enum SystemStatusWake {
    static let idle: Duration = .seconds(60)

    static func wait() async throws {
        if NSApp?.isActive == true || !AXIsProcessTrusted() {
            try await Task.sleep(for: .seconds(1))
            return
        }
        let wake = AsyncStream<Void> { continuation in
            let local = NotificationCenter.default
            let distributed = DistributedNotificationCenter.default()
            let active = local.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                continuation.yield()
            }
            let accessibility = distributed.addObserver(forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
                continuation.yield()
            }
            let timeout = Task { try? await Task.sleep(for: idle, tolerance: .seconds(5)); continuation.yield() }
            continuation.onTermination = { _ in
                local.removeObserver(active)
                distributed.removeObserver(accessibility)
                timeout.cancel()
            }
        }
        for await _ in wake { break }
        try Task.checkCancellation()
    }
}
