import AppKit

/// The switcher's explicit user selection, isolated from native AX/activation calls.
@MainActor
enum WindowActivation {
    static func perform(
        raise: () async -> Bool,
        request: () -> Bool,
        bringForward: () async -> Bool,
        isFrontmost: () -> Bool,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) }
    ) async -> Bool {
        guard !Task.isCancelled, await raise(), !Task.isCancelled else { return false }
        if !isFrontmost() {
            let requested = request()
            guard !Task.isCancelled else { return false }
            // Activation is a request, not proof of foreground ownership. A
            // switcher action is explicit user intent, so use the public AX
            // frontmost attribute if the other application still owns focus.
            if !isFrontmost() {
                let forwarded = await bringForward()
                guard requested || forwarded else { return false }
            }
            for _ in 0..<15 {
                guard !Task.isCancelled else { return false }
                if isFrontmost() { break }
                do { try await pause() } catch { return false }
            }
        }
        guard !Task.isCancelled, isFrontmost(), await raise(), !Task.isCancelled else { return false }
        return isFrontmost()
    }
}
