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

    func needsRefresh(at now: ContinuousClock.Instant = .now) -> Bool {
        guard let updatedAt else { return true }
        return updatedAt.duration(to: now) >= .seconds(5)
    }

    func readySnapshot(frontPID: pid_t?, livePIDs: Set<pid_t>? = nil) -> WindowCatalog.Snapshot? {
        // Freshness controls discovery, not presentation. Typing deliberately
        // pauses scans; the last inventory is still useful immediately afterward.
        guard let snapshot else { return nil }
        let windows = snapshot.windows.filter { livePIDs?.contains($0.pid) ?? true }
        let current = windows.first { $0.id == snapshot.current && $0.pid == frontPID }
            ?? windows.first { $0.pid == frontPID }
        return WindowCatalog.Snapshot(windows: windows, current: current?.id, completeness: snapshot.completeness)
    }
}

/// Released invocations never present late data; held invocations require rows.
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
