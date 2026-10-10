import Foundation

/// A ready-to-use inventory, refreshed independently of a Command–Tab invocation.
/// Refreshes never discard the previous snapshot or publish cancelled results.
@MainActor
final class WindowSwitcherCache {
    private(set) var snapshot: WindowCatalog.Snapshot?
    private var updatedAt: ContinuousClock.Instant?
    private var refresh: Task<WindowCatalog.Snapshot, Never>?
    private var revision: UInt64 = 0

    var isRefreshing: Bool { refresh != nil }

    func update(using load: @escaping @Sendable () async -> WindowCatalog.Snapshot) async -> WindowCatalog.Snapshot? {
        if let refresh {
            let token = revision
            let result = await refresh.value
            guard token == revision, !refresh.isCancelled, !Task.isCancelled, result.isPublishable else { return snapshot }
            return result
        }
        revision &+= 1
        let token = revision
        let task = Task { await load() }
        refresh = task
        let result = await task.value
        guard token == revision else { return snapshot }
        refresh = nil
        guard !task.isCancelled, !Task.isCancelled, result.isPublishable else { return snapshot }
        snapshot = result
        updatedAt = result.completeness == .complete ? .now : nil
        return result
    }

    func cancelRefresh() {
        revision &+= 1
        refresh?.cancel(); refresh = nil
    }

    func clear() { cancelRefresh(); snapshot = nil; updatedAt = nil }

    func noteFocused(_ id: UUID) {
        guard let snapshot, let window = snapshot.windows.first(where: { $0.id == id }) else { return }
        self.snapshot = WindowCatalog.Snapshot(windows: [window] + snapshot.windows.filter { $0.id != id }, current: id,
                                              completeness: snapshot.completeness)
    }

    func readySnapshot(frontPID: pid_t?, at now: ContinuousClock.Instant = .now) -> WindowCatalog.Snapshot? {
        // Background scans pause while typing. A later explicit invocation must
        // discover new/closed windows rather than use an indefinitely old list.
        guard let snapshot, let updatedAt, updatedAt.duration(to: now) < .seconds(5) else { return nil }
        let current = snapshot.windows.first { $0.id == snapshot.current && $0.pid == frontPID }
            ?? snapshot.windows.first { $0.pid == frontPID }
        return WindowCatalog.Snapshot(windows: snapshot.windows, current: current?.id, completeness: snapshot.completeness)
    }
}

/// Quick taps never present a panel; a held invocation can present only with data.
struct WindowSwitchPresentation {
    private(set) var sessionID: UInt64?
    private(set) var ready = false
    private(set) var delayElapsed = false
    private(set) var released = false

    var shouldShow: Bool { sessionID != nil && ready && delayElapsed && !released }

    mutating func begin(_ id: UInt64, ready: Bool) {
        sessionID = id; self.ready = ready; delayElapsed = false; released = false
    }
    mutating func loaded(_ id: UInt64) { if sessionID == id { ready = true } }
    mutating func elapsed(_ id: UInt64) { if sessionID == id { delayElapsed = true } }
    mutating func release(_ id: UInt64) { if sessionID == id { released = true } }
    mutating func cancel(_ id: UInt64) { if sessionID == id { sessionID = nil } }
}
